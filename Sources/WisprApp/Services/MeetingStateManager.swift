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
/// Two capture shapes are supported (see `MeetingMode`):
/// - `.online`: mic ("You") plus diarized system audio ("Others" / per-speaker).
/// - `.inPerson`: mic only, with the mic track itself diarized so each person in
///   the room becomes a numbered speaker and there is no privileged "You". No
///   system audio and no Screen Recording permission is involved.
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
    /// Always 0 in `.inPerson` mode, which does not capture system audio.
    var systemLevel: Float = 0

    /// Capture mode for the **next** meeting. Bound to the header toggle and
    /// seeded from the last remembered choice.
    ///
    /// Once a meeting starts this is copied to `transcript.mode`, which is the
    /// canonical mode for the running session — every mode-dependent decision
    /// (labelling, diarization, echo suppression) reads that frozen value rather
    /// than this binding, so a transcript can never mix two labelling schemes.
    ///
    /// Selecting in-person turns on diarization automatically: it is what
    /// separates the people in the room, and without it the whole room collapses
    /// into a single speaker. Switching back to online leaves the setting as the
    /// user last had it — online diarization stays opt-in.
    var mode: MeetingMode = .online {
        didSet {
            if mode == .inPerson {
                settingsStore.meetingDiarizationEnabled = true
            }
        }
    }

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

    /// Optional speaker-diarization engine. In online mode it diarizes the
    /// system-audio ("Others") track; in in-person mode it diarizes the mic track.
    /// `nil` disables diarization entirely (e.g. in tests). It is warmed up when
    /// `settingsStore.meetingDiarizationEnabled` is true, or unconditionally in
    /// in-person mode (where diarization is what makes the mode meaningful).
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
        self.mode = settingsStore.meetingInPersonMode ? .inPerson : .online
    }

    // MARK: - Meeting Lifecycle

    /// Starts a new meeting transcription session.
    func startMeeting() async {
        guard meetingState == .idle, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }

        Log.stateManager.debug("MeetingStateManager — starting meeting")

        // Capture the mode for this session and remember the choice for next time.
        let sessionMode = mode
        settingsStore.meetingInPersonMode = (sessionMode == .inPerson)
        // In-person meetings rely on diarization to tell participants apart, so
        // ensure it is on even when the mode was restored from a prior session
        // rather than toggled this launch.
        if sessionMode == .inPerson {
            settingsStore.meetingDiarizationEnabled = true
        }

        transcript = MeetingTranscript()
        transcript.mode = sessionMode
        errorMessage = nil
        diarizationActive = false

        do {
            let (micLevels, systemLevels) = try await meetingAudioEngine.startCapture(
                mode: sessionMode)

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
    /// upcoming chunks without blocking the recording start. On failure, degrades
    /// gracefully to plain "Others" labels.
    ///
    /// In-person mode always warms the diarizer: without it the whole room
    /// collapses into a single speaker, which defeats the mode. Online mode only
    /// warms it when the user opted into diarization.
    private func warmUpDiarizerIfEnabled() async {
        // `transcript.mode` is the frozen session mode, set once at startMeeting().
        let wantsDiarization =
            transcript.mode == .inPerson || settingsStore.meetingDiarizationEnabled
        guard wantsDiarization, let diarizer = meetingDiarizer else {
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
        let savedURL = await TranscriptIO.shared.save(completed)

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

    /// The transcript label for a microphone chunk.
    ///
    /// Online, the mic is always the local user, so it is labelled `.you` and the
    /// diarized index (if any) is ignored. In person the mic carries the whole
    /// room and there is no privileged "You": every chunk becomes a numbered
    /// participant, falling back to `.others(nil)` — rendered "Others" — while
    /// the diarizer is cold or switched off.
    ///
    /// Extracted from `transcribeMicAudio()` so this decision is testable without
    /// microphone hardware.
    static func micSpeaker(mode: MeetingMode, diarizedIndex: Int?) -> MeetingSpeaker {
        switch mode {
        case .online:
            return .you
        case .inPerson:
            return .others(speakerIndex: diarizedIndex)
        }
    }

    private func transcribeMicAudio() async {
        let audioStream = await meetingAudioEngine.micAudioStream
        let language = settingsStore.languageMode
        // The frozen session mode, not the live header binding: a transcript must
        // never mix two labelling schemes even if the toggle were ever unlocked.
        let isInPerson = transcript.mode == .inPerson

        for await chunk in audioStream {
            guard !Task.isCancelled else { break }
            guard chunk.samples.count >= 8000 else { continue }

            // In person, the mic carries the whole room, so it is the track we
            // diarize. Re-check per chunk: the diarizer may finish warming up
            // mid-meeting. Online, the mic is always "You" and never diarized.
            let diarizer = (isInPerson && diarizationActive) ? meetingDiarizer : nil

            // Feed the chunk to the diarizer before transcribing so its timeline
            // covers this window by the time we query the dominant speaker.
            await diarizer?.ingest(chunk.samples, at: chunk.startTime)

            do {
                let result = try await transcriptionEngine.transcribe(
                    chunk.samples, language: language)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                // Resolve the dominant speaker over the chunk's time window.
                // nil (cold-start or diarization off) renders as plain "Others".
                var speakerIndex: Int?
                if let diarizer {
                    let chunkEnd =
                        chunk.startTime
                        + Double(chunk.samples.count) / Double(MeetingAudioEngine.sampleRate)
                    speakerIndex = await diarizer.dominantSpeaker(
                        in: chunk.startTime...chunkEnd)
                }

                record(
                    MeetingTranscriptEntry(
                        speaker: Self.micSpeaker(
                            mode: transcript.mode, diarizedIndex: speakerIndex),
                        text: text
                    )
                )
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
    ///
    /// In-person mode bypasses echo suppression entirely: there is no remote
    /// audio, so the mechanism can only produce false positives (two people in a
    /// room saying similar short phrases).
    /// Internal rather than private so tests can drive it directly: the bypass
    /// depends on session state that is otherwise only reachable with live audio.
    func record(_ entry: MeetingTranscriptEntry) {
        guard transcript.mode == .online, settingsStore.meetingEchoSuppressionEnabled else {
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
