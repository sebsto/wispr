//
//  MeetingStateManager.swift
//  wispr
//
//  Coordinator for meeting transcription mode.
//  Manages audio capture, continuous transcription, and transcript assembly.
//

import AppKit
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

    // MARK: - Tasks

    private var recordingTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        meetingAudioEngine: MeetingAudioEngine,
        transcriptionEngine: any TranscriptionEngine,
        settingsStore: SettingsStore
    ) {
        self.meetingAudioEngine = meetingAudioEngine
        self.transcriptionEngine = transcriptionEngine
        self.settingsStore = settingsStore
    }

    // MARK: - Meeting Lifecycle

    /// Starts a new meeting transcription session.
    func startMeeting() async {
        guard meetingState == .idle else { return }

        Log.stateManager.debug("MeetingStateManager — starting meeting")

        transcript = MeetingTranscript()
        errorMessage = nil

        do {
            let (micLevels, systemLevels) = try await meetingAudioEngine.startCapture()

            meetingState = .recording
            isWindowVisible = true

            recordingTask = Task {
                await withTaskGroup(of: Void.self) { group in
                    group.addTask { await self.consumeMicLevels(micLevels) }
                    group.addTask { await self.consumeSystemLevels(systemLevels) }
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

    /// Stops the meeting and finalizes the transcript.
    func stopMeeting() async {
        guard meetingState == .recording else { return }

        Log.stateManager.debug("MeetingStateManager — stopping meeting")

        await meetingAudioEngine.flushBuffers()
        try? await Task.sleep(for: .milliseconds(500))

        recordingTask?.cancel()
        recordingTask = nil

        await meetingAudioEngine.stopCapture()

        meetingState = .idle
        micLevel = 0
        systemLevel = 0
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

    /// Copies the transcript to the clipboard.
    func copyTranscript() {
        let text = transcript.asPlainText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
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

                transcript.entries.append(
                    MeetingTranscriptEntry(speaker: .you, text: text)
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

        for await chunk in audioStream {
            guard !Task.isCancelled else { break }
            guard chunk.count >= 8000 else { continue }

            do {
                let result = try await transcriptionEngine.transcribe(chunk, language: language)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }

                transcript.entries.append(
                    MeetingTranscriptEntry(speaker: .others, text: text)
                )
            } catch {
                if case WisprError.emptyTranscription = error { continue }
                Log.stateManager.warning(
                    "MeetingStateManager — system transcription error: \(error.localizedDescription)"
                )
            }
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
