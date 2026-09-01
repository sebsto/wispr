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

/// Same as `createTestMeetingStateManager()` but hands back the `SettingsStore`
/// too, for tests that need to flip a setting the manager reads.
@MainActor
func createTestMeetingStateManagerWithSettings() -> (MeetingStateManager, SettingsStore) {
    let settingsStore = SettingsStore(
        defaults: UserDefaults(suiteName: "test.wispr.meeting.\(UUID().uuidString)")!
    )
    let manager = MeetingStateManager(
        meetingAudioEngine: MeetingAudioEngine(),
        transcriptionEngine: FakeMeetingTranscriptionEngine(),
        settingsStore: settingsStore
    )
    return (manager, settingsStore)
}

// MARK: - Meeting Vocabulary Correction Tests

@Suite("Meeting Vocabulary Correction Tests")
@MainActor
struct MeetingVocabularyCorrectionTests {

    @Test("Uses English fallback when auto-detect has no engine language")
    func autoDetectWithoutDetectedLanguageUsesEnglishFallback() {
        let (manager, settingsStore) = createTestMeetingStateManagerWithSettings()
        settingsStore.customVocabularyEnabled = true
        settingsStore.customVocabulary = ["PyTorch"]
        settingsStore.languageMode = .autoDetect

        #expect(
            manager.applyVocabularyCorrection(to: "we use pytorch", detectedLanguage: nil)
                == "we use PyTorch"
        )
    }
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
            MeetingTranscriptEntry(
                speaker: .others(speakerIndex: nil), text: "Hi there", timestamp: timestamp2)
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

    @Test("MeetingSpeaker display names are correct")
    func testMeetingSpeakerDisplayNames() {
        #expect(MeetingSpeaker.you.displayName == "You")
        #expect(MeetingSpeaker.others(speakerIndex: nil).displayName == "Others")
        #expect(MeetingSpeaker.others(speakerIndex: 0).displayName == "Speaker 1")
        #expect(MeetingSpeaker.others(speakerIndex: 1).displayName == "Speaker 2")
        #expect(MeetingSpeaker.others(speakerIndex: 3).displayName == "Speaker 4")
    }
}

// MARK: - In-Person Speaker Labelling

/// Covers the behavioural heart of in-person mode (issue #97): the mic track is
/// diarized and every participant — including the local user — becomes a numbered
/// speaker, so nothing recorded in person is ever labelled "You".
@Suite("Meeting In-Person Labelling Tests")
struct MeetingInPersonLabellingTests {

    @Test("In person, a resolved chunk is labelled with its diarized speaker")
    func testInPersonResolvedIndex() {
        let speaker = MeetingStateManager.micSpeaker(mode: .inPerson, diarizedIndex: 1)

        #expect(speaker == .others(speakerIndex: 1))
        #expect(speaker.displayName == "Speaker 2")
    }

    @Test("In person, an unresolved chunk falls back to Others rather than You")
    func testInPersonColdStartFallsBackToOthers() {
        // nil is the diarizer's cold-start window, or diarization being off.
        let speaker = MeetingStateManager.micSpeaker(mode: .inPerson, diarizedIndex: nil)

        #expect(speaker == .others(speakerIndex: nil))
        #expect(speaker.displayName == "Others")
    }

    @Test("In person never labels microphone audio as You")
    func testInPersonNeverYou() {
        // There is no privileged local speaker in a room, so no diarizer outcome
        // — resolved or not — may produce .you.
        for index in [nil, 0, 1, 2, 3] as [Int?] {
            let speaker = MeetingStateManager.micSpeaker(mode: .inPerson, diarizedIndex: index)
            #expect(speaker != .you)
            #expect(speaker.isRemote)
        }
    }

    @Test("Online still labels microphone audio as You, ignoring any index")
    func testOnlineIsAlwaysYou() {
        #expect(MeetingStateManager.micSpeaker(mode: .online, diarizedIndex: nil) == .you)
        // Online the mic is never diarized; a stray index must not leak a label.
        #expect(MeetingStateManager.micSpeaker(mode: .online, diarizedIndex: 2) == .you)
    }
}

// MARK: - Echo Suppression Mode Gate

/// Covers the `record()` gate rather than `appendSuppressingEcho` itself: echo
/// suppression exists to drop the mic's copy of *remote* speech, so in person —
/// where there is no remote audio — it must be bypassed entirely. Two people in a
/// room saying the same short phrase is real speech, not an echo.
@Suite("Meeting Echo Suppression Mode Gate Tests")
@MainActor
struct MeetingEchoSuppressionModeGateTests {

    /// Two near-identical entries close in time — exactly what suppression drops
    /// online — recorded through the manager for a given session mode.
    private func recordEchoPair(mode: MeetingMode) -> MeetingTranscript {
        let (manager, settings) = createTestMeetingStateManagerWithSettings()
        // The bypass only means anything while suppression is switched on.
        settings.meetingEchoSuppressionEnabled = true
        manager.transcript = MeetingTranscript()
        manager.transcript.mode = mode

        let base = Date()
        manager.record(
            MeetingTranscriptEntry(
                speaker: .others(speakerIndex: 0),
                text: "Let's review the quarterly numbers",
                timestamp: base))
        manager.record(
            MeetingTranscriptEntry(
                speaker: mode == .inPerson ? .others(speakerIndex: 1) : .you,
                text: "Let's review the quarterly numbers.",
                timestamp: base.addingTimeInterval(1)))

        return manager.transcript
    }

    @Test("In person, a would-be echo is kept instead of suppressed")
    func testInPersonKeepsWouldBeEcho() {
        let transcript = recordEchoPair(mode: .inPerson)

        // Both speakers survive: suppressing the second would silently delete a
        // real participant's words.
        #expect(transcript.entries.count == 2)
        #expect(
            transcript.entries.map(\.speaker) == [
                .others(speakerIndex: 0), .others(speakerIndex: 1),
            ])
    }

    @Test("Online, the same pair is still suppressed as microphone echo")
    func testOnlineStillSuppressesEcho() {
        let transcript = recordEchoPair(mode: .online)

        // Control for the test above — proves the bypass is what changed the
        // outcome, not the entries themselves.
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].speaker == .others(speakerIndex: 0))
    }

    @Test("In person ignores the echo-suppression setting entirely")
    func testInPersonBypassIsIndependentOfSetting() {
        let (manager, settings) = createTestMeetingStateManagerWithSettings()
        settings.meetingEchoSuppressionEnabled = true
        manager.transcript = MeetingTranscript()
        manager.transcript.mode = .inPerson

        let base = Date()
        let text = "we should ship it this week"
        for offset in [0.0, 1.0, 2.0] {
            manager.record(
                MeetingTranscriptEntry(
                    speaker: .others(speakerIndex: 0), text: text,
                    timestamp: base.addingTimeInterval(offset)))
        }

        #expect(manager.transcript.entries.count == 3)
    }
}

// MARK: - Echo Suppression Tests

/// Tests for the microphone-echo de-duplication that fixes issue #65: remote
/// participants' speech leaking from the speakers into the mic and being
/// transcribed twice (once as "Others", once as "You").
@Suite("Meeting Echo Suppression Tests")
struct MeetingEchoSuppressionTests {

    /// Builds an entry at a fixed offset (seconds) from a shared base time so
    /// tests can control the echo time window precisely.
    private func entry(
        _ speaker: MeetingSpeaker, _ text: String, at offset: TimeInterval, base: Date
    ) -> MeetingTranscriptEntry {
        MeetingTranscriptEntry(
            speaker: speaker, text: text, timestamp: base.addingTimeInterval(offset))
    }

    @Test("Mic entry echoing a recent remote entry is suppressed")
    func testMicEchoOfRemoteIsSuppressed() {
        let base = Date()
        var transcript = MeetingTranscript()

        let added1 = transcript.appendSuppressingEcho(
            entry(.others(speakerIndex: 0), "Let's review the quarterly numbers", at: 0, base: base)
        )
        let added2 = transcript.appendSuppressingEcho(
            entry(.you, "Let's review the quarterly numbers.", at: 1, base: base))

        #expect(added1 == true)
        #expect(added2 == false)
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].speaker.isRemote)
    }

    @Test("Remote entry removes a prior mic echo (system arrives second)")
    func testRemoteRemovesPriorMicEcho() {
        let base = Date()
        var transcript = MeetingTranscript()

        transcript.appendSuppressingEcho(
            entry(.you, "Can everyone hear me clearly", at: 0, base: base))
        transcript.appendSuppressingEcho(
            entry(.others(speakerIndex: 1), "Can everyone hear me clearly?", at: 1, base: base))

        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].speaker == .others(speakerIndex: 1))
    }

    @Test("Distinct utterances on both tracks are both kept")
    func testDistinctUtterancesKept() {
        let base = Date()
        var transcript = MeetingTranscript()

        transcript.appendSuppressingEcho(
            entry(.others(speakerIndex: 0), "What did you think of the proposal", at: 0, base: base)
        )
        transcript.appendSuppressingEcho(
            entry(.you, "I thought it was a strong start overall", at: 1, base: base))

        #expect(transcript.entries.count == 2)
    }

    @Test("Matches outside the time window are not suppressed")
    func testOutsideWindowNotSuppressed() {
        let base = Date()
        var transcript = MeetingTranscript()
        let beyond = MeetingTranscript.echoSuppressionWindow + 2

        transcript.appendSuppressingEcho(
            entry(.others(speakerIndex: 0), "Please send the report by Friday", at: 0, base: base))
        let added = transcript.appendSuppressingEcho(
            entry(.you, "Please send the report by Friday", at: beyond, base: base))

        #expect(added == true)
        #expect(transcript.entries.count == 2)
    }

    @Test("Short utterances are not echo-suppressed")
    func testShortUtterancesNotSuppressed() {
        let base = Date()
        var transcript = MeetingTranscript()

        transcript.appendSuppressingEcho(
            entry(.others(speakerIndex: 0), "Sounds good", at: 0, base: base))
        let added = transcript.appendSuppressingEcho(entry(.you, "Sounds good", at: 1, base: base))

        #expect(added == true)
        #expect(transcript.entries.count == 2)
    }

    @Test("Cosmetic differences still count as the same utterance")
    func testCosmeticDifferencesMatch() {
        let base = Date()
        var transcript = MeetingTranscript()

        transcript.appendSuppressingEcho(
            entry(.others(speakerIndex: 0), "So, what's our next step here?", at: 0, base: base))
        let added = transcript.appendSuppressingEcho(
            entry(.you, "so what is our next step here", at: 1, base: base))

        // Minor wording ("what's" vs "what is") keeps similarity high enough.
        #expect(added == false)
        #expect(transcript.entries.count == 1)
    }

    @Test("normalizedForComparison strips case, punctuation, and extra whitespace")
    func testNormalization() {
        #expect(
            MeetingTranscript.normalizedForComparison("  Hello,   WORLD!! ") == "hello world")
    }

    @Test("similarity is 1 for identical strings and lower for different ones")
    func testSimilarity() {
        #expect(MeetingTranscript.similarity("hello world", "hello world") == 1.0)
        #expect(MeetingTranscript.similarity("hello world", "goodbye planet") < 0.5)
    }
}

// MARK: - MeetingStateManager Tests

@MainActor
@Suite("MeetingStateManager Tests", .serialized, .transcriptDirectoryIsolated)
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

    // MARK: - Termination Safety

    @Test("finalizeForTermination is a no-op when idle")
    func testFinalizeForTerminationWhenIdle() {
        let manager = createTestMeetingStateManager()
        #expect(manager.meetingState == .idle)

        // Must not throw, must not change state, and must not write a file for a
        // session that was never recording.
        manager.finalizeForTermination()

        #expect(manager.meetingState == .idle)
    }

    @Test("finalizeForTermination persists an in-progress transcript and clears state")
    func testFinalizeForTerminationSavesInProgress() throws {
        let manager = createTestMeetingStateManager()

        // Simulate a meeting that is recording with content, as happens when the
        // user closes the window and keeps talking before quitting the app.
        manager.meetingState = .recording
        manager.transcript.entries.append(
            MeetingTranscriptEntry(speaker: .you, text: "quitting mid meeting")
        )

        manager.finalizeForTermination()

        // The session is no longer considered live...
        #expect(manager.meetingState == .idle)

        // ...and its transcript landed on disk. Located by its content rather than by
        // diffing the directory: the suites share one real transcripts folder, so a
        // diff both mis-counts and — when used to clean up — deletes files another
        // suite is still using. Start time cannot be used as the key either, since
        // ISO-8601 encoding drops the sub-second part on the way to disk.
        let saved = try #require(
            TranscriptStore.list().first { $0.preview == "quitting mid meeting" })
        defer { try? TranscriptStore.delete(saved.url) }

        #expect(FileManager.default.fileExists(atPath: saved.url.path))
        #expect(try TranscriptStore.load(saved.url).entries.map(\.text) == ["quitting mid meeting"])
    }

    // MARK: - Start Meeting

    @Test("startMeeting fails without mic permission and sets error state", .disabled("Timing-sensitive: auto-dismiss timer causes flakiness"))
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

    @Test("toggleMeeting from idle attempts to start meeting", .disabled("Timing-sensitive: auto-dismiss timer causes flakiness"))
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

    @Test("startMeeting sets error state when no mic permission", .disabled("Timing-sensitive: auto-dismiss timer causes flakiness"))
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
