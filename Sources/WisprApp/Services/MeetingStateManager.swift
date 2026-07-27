//
//  MeetingStateManager.swift
//  wispr
//
//  Coordinator for meeting transcription mode.
//  Manages audio capture, continuous transcription, and transcript assembly.
//

import Foundation
import Observation
import WisprCore
import os

/// State of the meeting transcription session.
enum MeetingState: Sendable, Equatable {
    case idle
    case recording
    case error(String)
}

/// Central coordinator for meeting transcription mode.
///
/// Orchestrates microphone capture, runs continuous chunked transcription,
/// and assembles a timestamped transcript.
///
/// Note: Currently captures microphone only. System audio capture (for remote
/// meeting participants) requires Screen Recording permission which is
/// incompatible with App Sandbox. Speaker labels default to "You" for all
/// entries until system audio support is added.
@MainActor
@Observable
final class MeetingStateManager {

    // MARK: - Published State

    /// Current meeting state.
    var meetingState: MeetingState = .idle

    /// The live transcript being built.
    var transcript: MeetingTranscript = MeetingTranscript()

    /// URL of the session saved by the most recent `stopMeeting()`, or `nil`
    /// when the last meeting was empty (nothing written). The window reads this
    /// to jump to the freshly archived transcript instead of leaving the user on
    /// an empty "Current Session".
    var lastSavedURL: URL?

    /// Audio level from microphone (0.0–1.0) for UI visualization.
    var micLevel: Float = 0

    /// Audio level from system audio (0.0–1.0) for UI visualization.
    /// Currently always 0 — system audio capture requires Screen Recording
    /// permission which is incompatible with App Sandbox.
    var systemLevel: Float = 0

    /// Error message, if any.
    var errorMessage: String?

    /// Whether the meeting window should be visible.
    var isWindowVisible: Bool = false

    /// Timer display string.
    var elapsedTime: String = "0:00"

    // MARK: - Dependencies

    private let meetingAudioEngine: MeetingAudioEngine
    private let transcriptionEngine: any TranscriptionEngine
    private let settingsStore: SettingsStore

    /// Optional speaker-diarization engine for the system-audio ("Others") track.
    /// `nil` disables diarization entirely (e.g. in tests). When present, it is
    /// only warmed up if `settingsStore.meetingDiarizationEnabled` is true.
    private let meetingDiarizer: MeetingDiarizer?

    /// Whether diarization is active for the current session (set at startMeeting).
    private var diarizationActive = false

    /// Guards against a second save while `stopMeeting()` is suspended.
    ///
    /// `stopMeeting()` awaits before it flips `meetingState` to `.idle`, so a quit
    /// during that window would let `finalizeForTermination()` see a still-recording
    /// session and write a second file.
    private var isStopping = false

    /// Guards against re-entrant `startMeeting()` while capture is being set up
    /// (the window between the first `await` and `meetingState = .recording`).
    private var isStarting = false

    // MARK: - Tasks

    private var recordingTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        meetingAudioEngine: MeetingAudioEngine,
        transcriptionEngine: any TranscriptionEngine,
        settingsStore: SettingsStore,
        meetingDiarizer: MeetingDiarizer? = nil
    ) {
        self.meetingAudioEngine = meetingAudioEngine
        self.transcriptionEngine = transcriptionEngine
        self.settingsStore = settingsStore
        self.meetingDiarizer = meetingDiarizer
    }

    // MARK: - Meeting Lifecycle

    /// Starts a new meeting transcription session.
    func startMeeting() async {
        guard meetingState == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        Log.stateManager.debug("MeetingStateManager — starting meeting")

        transcript = MeetingTranscript()
        errorMessage = nil
        diarizationActive = false

        do {
            let (micLevels, systemLevels) = try await meetingAudioEngine.startCapture()

            // Flip to recording immediately so the UI is responsive. The diarizer
            // (if enabled) warms up concurrently below — chunks that arrive before
            // it's ready simply render as "Others".
            meetingState = .recording
            isWindowVisible = true

            recordingTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.consumeMicLevels(micLevels) }
                    group.addTask { await self.consumeSystemLevels(systemLevels) }
                    group.addTask { await self.warmUpDiarizerIfEnabled() }
                    group.addTask { await self.transcribeMicAudio() }
                    group.addTask { await self.transcribeSystemAudio() }
                    group.addTask { await self.runTimer() }
                }
            }

        } catch {
            Log.stateManager.error(
                "MeetingStateManager — failed to start: \(error.localizedDescription)")
            await handleError("Failed to start meeting capture: \(error.localizedDescription)")
        }
    }

    /// Warms up the diarizer in the background when enabled, so it's ready for
    /// upcoming system-audio chunks without blocking the recording start.
    /// On failure, degrades gracefully to source-based "Others" labels.
    private func warmUpDiarizerIfEnabled() async {
        guard settingsStore.meetingDiarizationEnabled, let diarizer = meetingDiarizer else {
            return
        }
        do {
            try await diarizer.warmUp()
            guard !Task.isCancelled else { return }
            diarizationActive = true
        } catch {
            Log.stateManager.warning(
                "MeetingStateManager — diarizer warmup failed: \(error.localizedDescription). Continuing without diarization."
            )
        }
    }

    /// Stops the meeting and finalizes the transcript.
    func stopMeeting() async {
        guard meetingState == .recording, !isStopping else { return }
        isStopping = true
        defer { isStopping = false }

        Log.stateManager.debug("MeetingStateManager — stopping meeting")

        await meetingAudioEngine.flushBuffers()
        try? await Task.sleep(for: .milliseconds(500))

        recordingTask?.cancel()
        recordingTask = nil

        await meetingAudioEngine.stopCapture()
        // reset() is a safe no-op if the diarizer was never warmed up, so call it
        // unconditionally to avoid a race with the concurrent warmup task.
        await meetingDiarizer?.reset()
        diarizationActive = false

        // Persist the completed session to disk before it can be overwritten by a
        // subsequent startMeeting() (which resets `transcript`). Encoding and
        // writing happen off the main actor, but are awaited so the save is
        // guaranteed to complete before `transcript` can be replaced.
        let completed = transcript
        let savedURL = await Task.detached { TranscriptStore.save(completed) }.value

        // Return "Current Session" to an empty slate: the finished meeting is now
        // on disk and shown from history, so keeping its text in the live view
        // only duplicates the freshly archived row and confuses "what's live".
        transcript = MeetingTranscript()
        lastSavedURL = savedURL

        meetingState = .idle
        micLevel = 0
        systemLevel = 0
    }

    /// Persists an in-progress meeting synchronously, for use on app termination.
    ///
    /// `stopMeeting()` cannot be used from `applicationWillTerminate` because it
    /// is `async` and the app is torn down before the suspension resumes. This
    /// writes the transcript first and only then cancels the task group, so a
    /// meeting left running in the background — the window closed while
    /// recording continues — is never silently lost.
    ///
    /// Saving is silent by design: no prompt, no UI. Empty transcripts are
    /// skipped by `TranscriptStore.save`.
    func finalizeForTermination() {
        // `isStopping` means stopMeeting() is mid-flight and will save itself; it
        // has not yet flipped `meetingState`, so the state check alone would let
        // both write a file.
        guard meetingState == .recording, !isStopping else { return }

        let entryCount = transcript.entries.count
        Log.stateManager.debug(
            "MeetingStateManager — finalizing in-progress meeting on termination (\(entryCount) entries)"
        )
        TranscriptStore.save(transcript)

        recordingTask?.cancel()
        recordingTask = nil
        meetingState = .idle
    }

    /// Toggles between recording and stopped states.
    func toggleMeeting() async {
        switch meetingState {
        case .idle:
            await startMeeting()
        case .recording:
            await stopMeeting()
        case .error:
            meetingState = .idle
            errorMessage = nil
        }
    }

    /// Renames a diarized speaker in the live transcript.
    ///
    /// Mutates in place rather than writing back a snapshot: the transcription
    /// tasks append entries concurrently, so assigning a copy taken before an
    /// `await` would silently drop everything that arrived in between.
    ///
    /// Names resolve at display time, so this relabels all of the speaker's
    /// existing entries and every future one. Persistence happens at
    /// `stopMeeting()`, which saves the transcript including its names.
    func renameSpeaker(index: Int, to name: String?) {
        transcript.setName(name, forSpeakerIndex: index)
    }

    /// Copies the transcript to the clipboard.
    func copyTranscript() {
        let text = transcript.asPlainText()
        guard !text.isEmpty else { return }
        ClipboardService.copy(text)
    }

    // MARK: - Transcription

    private func transcribeMicAudio() async {
        let audioStream = await meetingAudioEngine.micAudioStream
        let language = settingsStore.languageMode

        for await chunk in audioStream {
            guard !Task.isCancelled else { break }
            guard chunk.count >= 8000 else { continue }

            do {
                let result = try await transcriptionEngine.transcribe(chunk, language: language)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                record(MeetingTranscriptEntry(speaker: .you, text: text))
            } catch {
                if case WisprError.emptyTranscription = error { continue }
                Log.stateManager.warning(
                    "MeetingStateManager — mic transcription error: \(error.localizedDescription)")
            }
        }
    }

    private func transcribeSystemAudio() async {
        let audioStream = await meetingAudioEngine.systemAudioStream
        let language = settingsStore.languageMode

        for await audioChunk in audioStream {
            guard !Task.isCancelled else { break }
            guard audioChunk.samples.count >= 8000 else { continue }

            // Re-check per chunk: the diarizer may finish warming up mid-meeting.
            let diarizer = diarizationActive ? meetingDiarizer : nil

            // Feed the chunk to the diarizer before transcribing so its timeline
            // covers this window by the time we query the dominant speaker.
            await diarizer?.ingest(audioChunk.samples, at: audioChunk.startTime)

            do {
                let result = try await transcriptionEngine.transcribe(
                    audioChunk.samples, language: language)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                // Resolve the dominant speaker over the chunk's time window.
                // nil (cold-start or diarization disabled) renders as "Others".
                var speakerIndex: Int?
                if let diarizer {
                    let chunkEnd =
                        audioChunk.startTime
                        + Double(audioChunk.samples.count) / Double(MeetingAudioEngine.sampleRate)
                    speakerIndex = await diarizer.dominantSpeaker(
                        in: audioChunk.startTime...chunkEnd)
                }

                record(
                    MeetingTranscriptEntry(speaker: .others(speakerIndex: speakerIndex), text: text)
                )
            } catch {
                if case WisprError.emptyTranscription = error { continue }
                Log.stateManager.warning(
                    "MeetingStateManager — system transcription error: \(error.localizedDescription)"
                )
            }
        }
    }

    /// Adds a transcript entry, applying microphone echo suppression when the
    /// setting is enabled. Echo suppression drops mic ("You") transcriptions that
    /// duplicate a recent remote ("Others") transcription — the result of remote
    /// speech leaking from the speakers into the mic (issue #65).
    private func record(_ entry: MeetingTranscriptEntry) {
        guard settingsStore.meetingEchoSuppressionEnabled else {
            transcript.entries.append(entry)
            return
        }
        if !transcript.appendSuppressingEcho(entry) {
            Log.stateManager.debug(
                "MeetingStateManager — suppressed microphone echo of remote audio")
        }
    }

    // MARK: - Audio Level Consumption

    private func consumeMicLevels(_ stream: AsyncStream<Float>) async {
        for await level in stream {
            guard !Task.isCancelled else { break }
            self.micLevel = level
        }
    }

    private func consumeSystemLevels(_ stream: AsyncStream<Float>) async {
        for await level in stream {
            guard !Task.isCancelled else { break }
            self.systemLevel = level
        }
    }

    // MARK: - Timer

    private func runTimer() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { break }
            self.elapsedTime = self.transcript.formattedDuration
        }
    }

    // MARK: - Cancellation

    /// Cancels all recording tasks immediately. Safe to call synchronously
    /// (e.g. from applicationWillTerminate).
    func cancelRecording() {
        recordingTask?.cancel()
        recordingTask = nil
    }

    // MARK: - Error Handling

    private func handleError(_ message: String) async {
        meetingState = .error(message)
        errorMessage = message

        // Auto-dismiss after 5 seconds
        try? await Task.sleep(for: .seconds(5))
        if case .error = meetingState {
            meetingState = .idle
            errorMessage = nil
        }
    }

}
