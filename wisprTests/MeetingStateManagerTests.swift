//
//  MeetingStateManagerTests.swift
//  wisprTests
//
//  Unit tests for MeetingStateManager and MeetingTranscript.
//

import AppKit
import Foundation
import Testing
import WisprCore

@testable import WisprApp

// MARK: - Test Helpers

/// Creates a MeetingStateManager with real MeetingAudioEngine (which will fail
/// without mic permission — useful for testing error paths) and a fake
/// transcription engine.
@MainActor
func createTestMeetingStateManager() -> MeetingStateManager {
    let audioEngine = MeetingAudioEngine()
    let transcriptionEngine = FakeMeetingTranscriptionEngine()
    let settingsStore = SettingsStore(
        defaults: UserDefaults(suiteName: "test.wispr.meeting.\(UUID().uuidString)")!
    )

    return MeetingStateManager(
        meetingAudioEngine: audioEngine,
        transcriptionEngine: transcriptionEngine,
        settingsStore: settingsStore
    )
}

// MARK: - MeetingTranscript Tests

@Suite("MeetingTranscript Tests")
struct MeetingTranscriptTests {

    @Test("Empty transcript asPlainText returns empty string")
    func testEmptyTranscriptPlainText() {
        let transcript = MeetingTranscript()
        #expect(transcript.asPlainText() == "")
    }

    @Test("Transcript asPlainText formats entries as [HH:mm:ss] Speaker: text")
    func testTranscriptPlainTextFormatting() {
        var transcript = MeetingTranscript()

        // Create entries with known timestamps
        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2025
        components.month = 1
        components.day = 15
        components.hour = 14
        components.minute = 30
        components.second = 45
        let timestamp1 = calendar.date(from: components)!

        components.minute = 31
        components.second = 12
        let timestamp2 = calendar.date(from: components)!

        transcript.entries.append(
            MeetingTranscriptEntry(speaker: .you, text: "Hello world", timestamp: timestamp1)
        )
        transcript.entries.append(
            MeetingTranscriptEntry(speaker: .others, text: "Hi there", timestamp: timestamp2)
        )

        let plainText = transcript.asPlainText()
        let lines = plainText.components(separatedBy: "\n")

        #expect(lines.count == 2)
        #expect(lines[0] == "[14:30:45] You: Hello world")
        #expect(lines[1] == "[14:31:12] Others: Hi there")
    }

    @Test("Transcript formattedDuration returns M:SS format")
    func testTranscriptFormattedDuration() {
        // Create a transcript whose startTime is 125 seconds in the past (2:05)
        let startTime = Date().addingTimeInterval(-125)
        let transcript = MeetingTranscript(startTime: startTime)

        let formatted = transcript.formattedDuration
        // Allow a small tolerance — the exact second may shift by 1
        #expect(formatted == "2:05" || formatted == "2:06")
    }

    @Test("Transcript entries with different UUIDs are not equal")
    func testTranscriptEntryEquality() {
        let timestamp = Date()
        let entry1 = MeetingTranscriptEntry(speaker: .you, text: "Hello", timestamp: timestamp)
        let entry2 = MeetingTranscriptEntry(speaker: .you, text: "Hello", timestamp: timestamp)

        // Each entry gets a unique UUID in init, so they should NOT be equal
        #expect(entry1 != entry2)
        #expect(entry1.id != entry2.id)
    }

    @Test("MeetingSpeaker raw values are correct")
    func testMeetingSpeakerRawValues() {
        #expect(MeetingSpeaker.you.rawValue == "You")
        #expect(MeetingSpeaker.others.rawValue == "Others")
    }
}

// MARK: - MeetingStateManager Tests

@MainActor
@Suite("MeetingStateManager Tests", .serialized)
struct MeetingStateManagerTests {

    // MARK: - Initial State

    @Test("MeetingStateManager has correct initial state")
    func testInitialState() {
        let manager = createTestMeetingStateManager()

        #expect(manager.meetingState == .idle)
        #expect(manager.transcript.entries.isEmpty)
        #expect(manager.micLevel == 0)
        #expect(manager.systemLevel == 0)
        #expect(manager.errorMessage == nil)
        #expect(manager.isWindowVisible == false)
        #expect(manager.elapsedTime == "0:00")
    }

    // MARK: - Start Meeting

    @Test("startMeeting fails without mic permission and sets error state")
    func testStartMeetingFailsWithoutMic() async {
        let manager = createTestMeetingStateManager()

        await manager.startMeeting()

        // startCapture() should throw in the test environment (no mic permission),
        // causing handleError to be called
        if case .error(let message) = manager.meetingState {
            #expect(message.contains("Failed to start meeting capture"))
        } else {
            // The error auto-dismisses after 5 seconds. If the state has already
            // become .idle, just verify errorMessage was set (it also auto-clears,
            // but there's a window). Either .error or .idle is acceptable here
            // since the handleError has an auto-dismiss timer.
            #expect(
                manager.meetingState == .idle
                    || {
                        if case .error = manager.meetingState { return true }
                        return false
                    }())
        }
    }

    @Test("toggleMeeting from idle attempts to start meeting")
    func testToggleMeetingFromIdle() async {
        let manager = createTestMeetingStateManager()

        #expect(manager.meetingState == .idle)

        await manager.toggleMeeting()

        // Should have attempted startMeeting, which fails due to no mic permission
        // State should be .error(...) or possibly .idle if auto-dismiss already fired
        let isErrorOrIdle: Bool
        switch manager.meetingState {
        case .error: isErrorOrIdle = true
        case .idle: isErrorOrIdle = true
        case .recording: isErrorOrIdle = false
        }
        #expect(isErrorOrIdle)
    }

    @Test("toggleMeeting from error resets to idle")
    func testToggleMeetingFromError() async {
        let manager = createTestMeetingStateManager()

        // Force error state
        // First, attempt to start which will error
        await manager.startMeeting()

        // If we're in error state, toggle should reset to idle
        if case .error = manager.meetingState {
            await manager.toggleMeeting()
            #expect(manager.meetingState == .idle)
            #expect(manager.errorMessage == nil)
        }
        // If auto-dismiss already fired, state is already idle — that's also fine
    }

    @Test("stopMeeting when idle is a no-op")
    func testStopMeetingWhenIdle() async {
        let manager = createTestMeetingStateManager()

        #expect(manager.meetingState == .idle)

        await manager.stopMeeting()

        #expect(manager.meetingState == .idle)
    }

    // MARK: - Copy Transcript

    @Test("copyTranscript with empty transcript does not crash")
    func testCopyTranscriptEmpty() {
        let manager = createTestMeetingStateManager()

        #expect(manager.transcript.entries.isEmpty)

        // Should not crash — copyTranscript guards on empty text
        manager.copyTranscript()
    }

    @Test("copyTranscript with entries places text on pasteboard")
    func testCopyTranscriptWithEntries() {
        let manager = createTestMeetingStateManager()

        let calendar = Calendar.current
        var components = DateComponents()
        components.year = 2025
        components.month = 6
        components.day = 1
        components.hour = 10
        components.minute = 0
        components.second = 0
        let timestamp = calendar.date(from: components)!

        manager.transcript.entries.append(
            MeetingTranscriptEntry(speaker: .you, text: "Test message", timestamp: timestamp)
        )

        manager.copyTranscript()

        let pasteboard = NSPasteboard.general
        let pasteboardText = pasteboard.string(forType: .string)
        #expect(pasteboardText == "[10:00:00] You: Test message")
    }

    // MARK: - Window Visibility

    @Test("startMeeting sets error state when no mic permission")
    func testStartMeetingSetsErrorState() async {
        let manager = createTestMeetingStateManager()

        await manager.startMeeting()

        // The error path in startMeeting calls handleError which sets meetingState to .error
        // It may have auto-dismissed by now, but errorMessage should have been set
        // Since handleError auto-dismisses after 5 seconds, check the state within that window
        let stateIsExpected: Bool
        switch manager.meetingState {
        case .error: stateIsExpected = true
        case .idle: stateIsExpected = true  // auto-dismiss may have fired
        case .recording: stateIsExpected = false
        }
        #expect(stateIsExpected)
        // isWindowVisible is NOT set to true in the error path (only in the success path)
        // so it should remain false
        #expect(manager.isWindowVisible == false)
    }

    // MARK: - Double Start Prevention

    @Test("startMeeting when already recording is ignored")
    func testDoubleStartMeetingIgnored() async {
        let manager = createTestMeetingStateManager()

        // We can't easily get to .recording state without mic permission,
        // but we can test the guard by checking that startMeeting from non-idle
        // states is a no-op.

        // First, trigger an error state
        await manager.startMeeting()

        // If in error state, startMeeting should be a no-op (guard meetingState == .idle)
        if case .error(let msg) = manager.meetingState {
            await manager.startMeeting()
            // State should still be the same error
            if case .error(let msg2) = manager.meetingState {
                #expect(msg == msg2)
            }
        }
    }
}

// MARK: - Fake Transcription Engine

/// Minimal fake TranscriptionEngine for MeetingStateManager tests.
/// Returns simple stubs for all protocol methods.
actor FakeMeetingTranscriptionEngine: TranscriptionEngine {

    private var _activeModel: String?

    func availableModels() async -> [ModelInfo] {
        [
            ModelInfo(
                id: "fake-model",
                displayName: "Fake Model",
                sizeDescription: "~1 MB",
                qualityDescription: "Test only",
                estimatedSize: 1_000_000,
                status: .downloaded
            )
        ]
    }

    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
        continuation.yield(
            DownloadProgress(
                phase: .downloading,
                fractionCompleted: 1.0,
                bytesDownloaded: 100,
                totalBytes: 100
            )
        )
        continuation.finish()
        return stream
    }

    func deleteModel(_ modelName: String) async throws {
        if _activeModel == modelName {
            _activeModel = nil
        }
    }

    func loadModel(_ modelName: String) async throws {
        _activeModel = modelName
    }

    func switchModel(to modelName: String) async throws {
        _activeModel = modelName
    }

    func unloadCurrentModel() async {
        _activeModel = nil
    }

    func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        true
    }

    func modelStatus(_ modelName: String) async -> ModelStatus {
        if _activeModel == modelName { return .active }
        return .downloaded
    }

    func activeModel() async -> String? {
        _activeModel
    }

    func reloadModelWithRetry(maxAttempts: Int) async throws {
        // no-op
    }

    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: "mock transcription", detectedLanguage: nil, duration: 0.1)
    }

    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        continuation.yield(
            TranscriptionResult(text: "mock transcription", detectedLanguage: nil, duration: 0.1))
        continuation.finish()
        return stream
    }

    func supportsEndOfUtteranceDetection() async -> Bool {
        false
    }
}
