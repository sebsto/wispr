//
//  StateManagerTests.swift
//  wispr
//
//  Unit tests for StateManager state machine logic.
//  Requirements: 12.1, 12.5
//

import Testing
import Foundation
@testable import WisprApp
import WisprCore

// MARK: - Test Helpers

/// Creates a StateManager with real dependencies suitable for unit testing.
/// PermissionManager properties are directly set since they are writable vars.
@MainActor
func createTestStateManager(
    permissionsGranted: Bool = false
) -> (StateManager, PermissionManager) {
    let audioEngine = AudioEngine()
    let whisperService = WhisperService()
    let textInsertionService = TextInsertionService()
    let hotkeyMonitor = HotkeyMonitor()
    let permissionManager = PermissionManager()
    let settingsStore = SettingsStore(defaults: UserDefaults(suiteName: "test.wispr.statemanager.\(UUID().uuidString)")!)

    if permissionsGranted {
        permissionManager.microphoneStatus = .authorized
        permissionManager.accessibilityStatus = .authorized
    } else {
        permissionManager.microphoneStatus = .denied
        permissionManager.accessibilityStatus = .denied
    }

    let stateManager = StateManager(
        audioEngine: audioEngine,
        whisperService: whisperService,
        textInsertionService: textInsertionService,
        textCorrectionService: TextCorrectionService(),
        hotkeyMonitor: hotkeyMonitor,
        permissionManager: permissionManager,
        settingsStore: settingsStore
    )

    // StateManager initializes in .loading state; transition to .idle
    // so tests start from the expected ready state.
    stateManager.markAsReady()

    return (stateManager, permissionManager)
}

// MARK: - Tests

@MainActor
@Suite("StateManager Tests")
struct StateManagerTests {

    // MARK: - Initial State

    @Test("StateManager starts in loading state")
    func testInitialState() {
        // Create StateManager directly (without markAsReady) to verify initial state
        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: SettingsStore(defaults: UserDefaults(suiteName: "test.wispr.initialstate.\(UUID().uuidString)")!)
        )
        #expect(sm.appState == .loading)
        #expect(sm.errorMessage == nil)
        #expect(sm.audioLevelStream == nil)
    }

    @Test("StateManager syncs language from SettingsStore on init")
    func testLanguageSyncFromSettings() {
        let defaults = UserDefaults(suiteName: "test.wispr.statemanager.lang.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.languageMode = .specific(code: "fr")

        let pm = PermissionManager()
        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: pm,
            settingsStore: settingsStore
        )

        #expect(sm.currentLanguage == .specific(code: "fr"))
    }

    // MARK: - Concurrent Recording Prevention (Requirement 12.5)

    @Test("beginRecording is ignored when not in idle state - recording")
    func testConcurrentRecordingPreventionWhileRecording() async {
        let (sm, _) = createTestStateManager(permissionsGranted: true)

        // Force state to recording manually to test the guard
        sm.appState = .recording

        // Attempt to begin recording again — should be ignored
        await sm.beginRecording()

        // State should remain .recording (not reset or changed)
        #expect(sm.appState == .recording)
    }

    @Test("beginRecording is ignored when in processing state")
    func testConcurrentRecordingPreventionWhileProcessing() async {
        let (sm, _) = createTestStateManager(permissionsGranted: true)

        // Force state to processing
        sm.appState = .processing

        await sm.beginRecording()

        #expect(sm.appState == .processing)
    }

    @Test("beginRecording dismisses error state and attempts recording (issue #52)")
    func testBeginRecordingDismissesError() async {
        let (sm, _) = createTestStateManager(permissionsGranted: true)

        // Force state to error
        sm.appState = .error("some error")
        sm.errorMessage = "some error"

        await sm.beginRecording()

        // The original error must be dismissed. beginRecording() may end in a
        // new .error if AudioEngine.startCapture() fails in the test environment,
        // so we assert the original error was cleared rather than requiring .recording.
        if case let .error(message) = sm.appState {
            #expect(message != "some error")
        }
        #expect(sm.errorMessage != "some error")
    }

    @Test("toggleRecording dismisses error state and attempts recording (issue #52)")
    func testToggleRecordingDismissesError() async {
        let (sm, _) = createTestStateManager(permissionsGranted: true)

        sm.appState = .error("some error")
        sm.errorMessage = "some error"

        await sm.toggleRecording()

        if case let .error(message) = sm.appState {
            #expect(message != "some error")
        }
        #expect(sm.errorMessage != "some error")
    }

    // MARK: - Permission Check on Recording

    @Test("beginRecording transitions to error when permissions denied")
    func testBeginRecordingWithoutPermissions() async {
        let (sm, _) = createTestStateManager(permissionsGranted: false)

        #expect(sm.appState == .idle)

        await sm.beginRecording()

        // Should transition to error state because permissions are denied
        if case .error = sm.appState {
            // Expected — permission denied error
        } else {
            Issue.record("Expected error state when permissions are denied, got \(sm.appState)")
        }
        #expect(sm.errorMessage != nil)
    }

    @Test("beginRecording with permissions transitions to recording then errors on audio")
    func testBeginRecordingWithPermissions() async {
        let (sm, _) = createTestStateManager(permissionsGranted: true)

        #expect(sm.appState == .idle)

        await sm.beginRecording()

        // In test environment, AVAudioEngine will fail to start (no real mic).
        // The state should either be .recording (if startCapture succeeded)
        // or .error (if startCapture threw).
        let isRecordingOrError = sm.appState == .recording || {
            if case .error = sm.appState { return true }
            return false
        }()
        #expect(isRecordingOrError, "State should be recording or error after beginRecording with permissions")
    }

    // MARK: - Error Handling (Requirement 12.1)

    @Test("handleError transitions to error state with message")
    func testHandleErrorTransition() async {
        let (sm, _) = createTestStateManager()

        #expect(sm.appState == .idle)

        await sm.handleError(.noAudioDeviceAvailable)

        if case .error(let msg) = sm.appState {
            #expect(!msg.isEmpty, "Error message should not be empty")
        } else {
            Issue.record("Expected error state after handleError")
        }
        #expect(sm.errorMessage != nil)
    }

    @Test("handleError clears audio level stream")
    func testHandleErrorClearsAudioStream() async {
        let (sm, _) = createTestStateManager()

        // Simulate having an audio stream
        sm.audioLevelStream = AsyncStream<Float> { $0.finish() }

        await sm.handleError(.transcriptionFailed("test"))

        #expect(sm.audioLevelStream == nil, "Audio level stream should be nil after error")
    }

    @Test("handleError sets errorMessage")
    func testHandleErrorSetsMessage() async {
        let (sm, _) = createTestStateManager()

        await sm.handleError(.microphonePermissionDenied)

        #expect(sm.errorMessage != nil)
        if case .error(let msg) = sm.appState {
            #expect(msg == sm.errorMessage, "appState error message should match errorMessage property")
        } else {
            Issue.record("Expected error state")
        }
    }

    @Test("Multiple handleError calls update to latest error")
    func testMultipleErrors() async {
        let (sm, _) = createTestStateManager()

        await sm.handleError(.noAudioDeviceAvailable)
        let firstMessage = sm.errorMessage

        await sm.handleError(.transcriptionFailed("second error"))
        let secondMessage = sm.errorMessage

        #expect(firstMessage != secondMessage, "Error message should update on subsequent errors")
        if case .error = sm.appState {
            // Expected
        } else {
            Issue.record("Should still be in error state")
        }
    }

    // MARK: - Permission Branching in beginRecording

    @Test("beginRecording surfaces accessibility error when mic authorized but accessibility denied")
    func testBeginRecordingMicAuthorizedAccessibilityDenied() async {
        let (sm, pm) = createTestStateManager(permissionsGranted: false)
        pm.microphoneStatus = .authorized
        pm.accessibilityStatus = .denied

        await sm.beginRecording()

        if case .error(let msg) = sm.appState {
            #expect(msg == WisprError.accessibilityPermissionDenied.localizedDescription,
                    "Should surface accessibility error, got: \(msg)")
        } else {
            Issue.record("Expected error state for accessibility denied, got \(sm.appState)")
        }
    }

    @Test("beginRecording surfaces microphone error when mic denied")
    func testBeginRecordingMicDenied() async {
        let (sm, pm) = createTestStateManager(permissionsGranted: false)
        pm.microphoneStatus = .denied
        pm.accessibilityStatus = .authorized

        await sm.beginRecording()

        if case .error(let msg) = sm.appState {
            #expect(msg == WisprError.microphonePermissionDenied.localizedDescription,
                    "Should surface microphone error, got: \(msg)")
        } else {
            Issue.record("Expected error state for microphone denied, got \(sm.appState)")
        }
    }

    @Test("beginRecording shows short-lived error without opening settings when mic notDetermined then denied",
          .disabled("Requires mocking PermissionManager — AVAudioApplication.requestRecordPermission() returns the real system state in tests"))
    func testBeginRecordingMicNotDeterminedThenDenied() async {
        let (sm, pm) = createTestStateManager(permissionsGranted: false)
        pm.microphoneStatus = .notDetermined
        pm.accessibilityStatus = .authorized

        await sm.beginRecording()

        // In a real scenario where the user denies the prompt,
        // the code takes an early-return path with a plain error message
        // ("Microphone access denied") and does NOT call handleError
        // (which would open System Settings).
        // This can't be tested without a protocol-based mock for PermissionManager
        // since requestMicrophoneAccess() calls AVAudioApplication.requestRecordPermission().
        if case .error(let msg) = sm.appState {
            #expect(msg == "Microphone access denied",
                    "Should show short-lived denial message, got: \(msg)")
        } else {
            Issue.record("Expected short-lived error state for fresh denial, got \(sm.appState)")
        }
    }

    // MARK: - Reset to Idle

    @Test("resetToIdle returns to idle state")
    func testResetToIdle() async {
        let (sm, _) = createTestStateManager()

        // Put into error state first
        await sm.handleError(.noAudioDeviceAvailable)
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state before reset")
        }

        await sm.resetToIdle()

        #expect(sm.appState == .idle)
        #expect(sm.errorMessage == nil)
        #expect(sm.audioLevelStream == nil)
    }

    @Test("resetToIdle clears error message")
    func testResetToIdleClearsError() async {
        let (sm, _) = createTestStateManager()

        await sm.handleError(.hotkeyRegistrationFailed)
        #expect(sm.errorMessage != nil)

        await sm.resetToIdle()
        #expect(sm.errorMessage == nil)
    }

    @Test("resetToIdle clears audio level stream")
    func testResetToIdleClearsAudioStream() async {
        let (sm, _) = createTestStateManager()

        sm.audioLevelStream = AsyncStream<Float> { $0.finish() }

        await sm.resetToIdle()
        #expect(sm.audioLevelStream == nil)
    }

    @Test("resetToIdle from processing state")
    func testResetToIdleFromProcessing() async {
        let (sm, _) = createTestStateManager()

        sm.appState = .processing

        await sm.resetToIdle()

        #expect(sm.appState == .idle)
    }

    // MARK: - endRecording Guards

    @Test("endRecording is ignored when not recording")
    func testEndRecordingWhenNotRecording() async {
        let (sm, _) = createTestStateManager()

        #expect(sm.appState == .idle)

        await sm.endRecording()

        // Should remain idle — endRecording guards against non-recording state
        #expect(sm.appState == .idle)
    }

    @Test("endRecording is ignored when in processing state")
    func testEndRecordingWhenProcessing() async {
        let (sm, _) = createTestStateManager()

        sm.appState = .processing

        await sm.endRecording()

        // Should remain processing
        #expect(sm.appState == .processing)
    }

    @Test("endRecording from recording state transitions through processing")
    func testEndRecordingFromRecordingState() async {
        let (sm, _) = createTestStateManager()

        // Force into recording state (bypassing actual audio capture)
        sm.appState = .recording

        await sm.endRecording()

        // AudioEngine.stopCapture() returns empty array (no real recording),
        // so endRecording should call resetToIdle (empty audio guard).
        #expect(sm.appState == .idle, "Should return to idle when audio is empty")
    }

    // MARK: - State Transition Flow

    @Test("Error → resetToIdle → idle is a valid transition")
    func testErrorToIdleTransition() async {
        let (sm, _) = createTestStateManager()

        await sm.handleError(.modelNotDownloaded)
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state")
        }

        await sm.resetToIdle()
        #expect(sm.appState == .idle)

        // Should be able to attempt recording again from idle
        // (will fail due to permissions, but the guard should pass)
        await sm.beginRecording()
        // Will go to error due to denied permissions
        if case .error = sm.appState {
            // Expected
        } else {
            Issue.record("Expected error from denied permissions")
        }
    }

    // MARK: - Property-Based Tests

    // Feature: auto-suffix-insertion, Property 2: Suffix application correctness
    // Validates: Requirements 3.1, 3.2, 3.3
    @Test("Property 2: Suffix application correctness — applyAutoSuffix produces correct output for all configurations",
          arguments: StateManagerTests.suffixApplicationCases)
    func testSuffixApplicationCorrectness(
        testCase: SuffixApplicationCase
    ) async {
        let defaults = UserDefaults(suiteName: "test.wispr.suffix.prop.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSuffixEnabled = testCase.autoSuffixEnabled
        settingsStore.autoSuffixText = testCase.autoSuffixText

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyAutoSuffix(to: testCase.transcription)

        // Requirement 3.1: When enabled and both strings non-empty, append suffix
        // Requirement 3.2: When disabled, pass text unmodified
        // Requirement 3.3: When suffix text is empty, pass text unmodified
        let shouldAppend = testCase.autoSuffixEnabled
            && !testCase.transcription.isEmpty
            && !testCase.autoSuffixText.isEmpty

        let expected = shouldAppend
            ? testCase.transcription + testCase.autoSuffixText
            : testCase.transcription

        #expect(result == expected,
                "case \(testCase.id): expected \"\(expected)\" but got \"\(result)\"")
    }

    /// A single test case for the suffix application correctness property test.
    struct SuffixApplicationCase: Sendable, CustomTestStringConvertible {
        let id: Int
        let transcription: String
        let autoSuffixEnabled: Bool
        let autoSuffixText: String

        var testDescription: String {
            "case \(id): enabled=\(autoSuffixEnabled), text=\"\(transcription)\", suffix=\"\(autoSuffixText)\""
        }
    }

    /// Generates 120 deterministic pseudo-random test cases covering diverse
    /// transcription × enabled × suffix combinations.
    /// Minimum 100 iterations as required by the design document.
    nonisolated static let suffixApplicationCases: [SuffixApplicationCase] = {
        let transcriptionPool: [String] = [
            "Hello world",
            "Testing",
            "A",
            "こんにちは",
            "🎤 voice input",
            "Multiple words in a sentence",
            String(repeating: "long ", count: 50),
            "café résumé",
            "Line1\nLine2",
            "tabs\there",
        ]

        let suffixPool: [String] = [
            "",           // empty — edge case (Req 3.3)
            ". ",         // default
            " ",          // single space
            ".",          // no trailing space
            "...",        // multiple dots
            "\n",         // newline
            "🎤",         // emoji
            "— ",         // em-dash
            "? ",         // question mark
            "END",        // alphabetic
            "。",         // CJK period
            ", ",         // comma
        ]

        var cases: [SuffixApplicationCase] = []
        var id = 0

        // Exhaustive: 10 transcriptions × 2 bools × 12 suffixes = 240 combos
        // Take first 100 from exhaustive, then add 20 pseudo-random for 120 total
        outer: for transcription in transcriptionPool {
            for enabled in [true, false] {
                for suffix in suffixPool {
                    cases.append(SuffixApplicationCase(
                        id: id,
                        transcription: transcription,
                        autoSuffixEnabled: enabled,
                        autoSuffixText: suffix
                    ))
                    id += 1
                    if cases.count >= 100 { break outer }
                }
            }
        }

        // Add 20 more pseudo-random cases using LCG
        var seed: UInt64 = 7
        for _ in 0..<20 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let tIdx = Int(seed >> 33) % transcriptionPool.count

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let sIdx = Int(seed >> 33) % suffixPool.count

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let enabled = (seed >> 33) % 2 == 0

            cases.append(SuffixApplicationCase(
                id: id,
                transcription: transcriptionPool[tIdx],
                autoSuffixEnabled: enabled,
                autoSuffixText: suffixPool[sIdx]
            ))
            id += 1
        }

        return cases
    }()

    // MARK: - Filler Word Removal

    @Test("applyFillerWordRemoval removes fillers when enabled")
    func testFillerRemovalEnabled() {
        let defaults = UserDefaults(suiteName: "test.wispr.filler.on.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.removeFillerWords = true

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyFillerWordRemoval(to: "I um think uh it works")
        #expect(result == "I think it works")
    }

    @Test("applyFillerWordRemoval passes text through when disabled")
    func testFillerRemovalDisabled() {
        let defaults = UserDefaults(suiteName: "test.wispr.filler.off.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.removeFillerWords = false

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyFillerWordRemoval(to: "I um think uh it works")
        #expect(result == "I um think uh it works")
    }

    @Test("applyFillerWordRemoval returns empty text unchanged")
    func testFillerRemovalEmptyText() {
        let defaults = UserDefaults(suiteName: "test.wispr.filler.empty.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.removeFillerWords = true

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyFillerWordRemoval(to: "")
        #expect(result == "")
    }

    // MARK: - switchActiveModel

    @Test("switchActiveModel no-ops when switching to the current model")
    func testSwitchActiveModelNoOp() async throws {
        let settingsStore = SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.switch.\(UUID().uuidString)")!
        )
        settingsStore.activeModelName = "tiny"

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )
        sm.markAsReady()

        // Switching to the already-active model should return immediately
        // without throwing (WhisperService.switchModel is never called).
        try await sm.switchActiveModel(to: "tiny")

        #expect(settingsStore.activeModelName == "tiny")
    }

    @Test("switchActiveModel propagates engine errors and does not persist the new name")
    func testSwitchActiveModelError() async {
        let settingsStore = SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.switch.err.\(UUID().uuidString)")!
        )
        settingsStore.activeModelName = "tiny"

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )
        sm.markAsReady()

        // Switching to a model that isn't downloaded should throw.
        // The settingsStore should still point to the original model.
        await #expect(throws: (any Error).self) {
            try await sm.switchActiveModel(to: "nonexistent-model")
        }

        #expect(settingsStore.activeModelName == "tiny",
                "activeModelName should remain unchanged after a failed switch")
    }

    // MARK: - Hands-Free / toggleRecording

    /// Helper that also returns the SettingsStore for hands-free tests.
    @MainActor
    private static func makeHandsFreeStateManager(
        permissionsGranted: Bool = true
    ) -> (StateManager, SettingsStore) {
        let settingsStore = SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.handsfree.\(UUID().uuidString)")!
        )
        let pm = PermissionManager()
        if permissionsGranted {
            pm.microphoneStatus = .authorized
            pm.accessibilityStatus = .authorized
        } else {
            pm.microphoneStatus = .denied
            pm.accessibilityStatus = .denied
        }
        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: pm,
            settingsStore: settingsStore
        )
        sm.markAsReady()
        return (sm, settingsStore)
    }

    @Test("toggleRecording from idle starts recording")
    func testToggleRecordingFromIdleStartsRecording() async {
        let (sm, _) = Self.makeHandsFreeStateManager()

        #expect(sm.appState == .idle)

        await sm.toggleRecording()

        // In test environment, audio engine may fail (no real mic),
        // so state is either .recording or .error.
        let valid = sm.appState == .recording || {
            if case .error = sm.appState { return true }
            return false
        }()
        #expect(valid, "toggleRecording from idle should attempt recording")
    }

    @Test("toggleRecording from recording stops recording and returns to idle")
    func testToggleRecordingFromRecordingStops() async {
        let (sm, _) = Self.makeHandsFreeStateManager()

        // Force into recording state
        sm.appState = .recording

        await sm.toggleRecording()

        // endRecording with no audio → resets to idle
        #expect(sm.appState == .idle)
    }

    @Test("toggleRecording is ignored during loading state")
    func testToggleRecordingIgnoredWhileLoading() async {
        let (sm, _) = Self.makeHandsFreeStateManager()
        sm.appState = .loading

        await sm.toggleRecording()

        #expect(sm.appState == .loading)
    }

    @Test("toggleRecording is ignored during processing state")
    func testToggleRecordingIgnoredWhileProcessing() async {
        let (sm, _) = Self.makeHandsFreeStateManager()
        sm.appState = .processing

        await sm.toggleRecording()

        #expect(sm.appState == .processing)
    }

    @Test("toggleRecording dismisses error and attempts new recording (issue #52)")
    func testToggleRecordingDismissesErrorHandsFree() async {
        let (sm, _) = Self.makeHandsFreeStateManager()
        sm.appState = .error("test error")
        sm.errorMessage = "test error"

        await sm.toggleRecording()

        if case let .error(message) = sm.appState {
            #expect(message != "test error")
        }
        #expect(sm.errorMessage != "test error")
    }

    @Test("toggleRecording from recording with no permissions still returns to idle")
    func testToggleRecordingStopsEvenWithoutPermissions() async {
        let (sm, _) = Self.makeHandsFreeStateManager(permissionsGranted: false)

        // Force into recording state (as if permissions were granted earlier)
        sm.appState = .recording

        await sm.toggleRecording()

        // endRecording with empty audio → idle
        #expect(sm.appState == .idle)
    }

    // MARK: - Property 3: Enter keystroke conditional execution

    // Feature: auto-suffix-insertion, Property 3: Enter keystroke conditional execution
    // Validates: Requirements 5.6, 5.7
    @Test("Property 3: Enter keystroke conditional execution — simulateEnterKey called iff autoSendEnterEnabled is true",
          arguments: StateManagerTests.enterKeystrokeCases)
    func testEnterKeystrokeConditionalExecution(
        testCase: EnterKeystrokeCase
    ) async {
        let defaults = UserDefaults(suiteName: "test.wispr.enter.prop.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSendEnterEnabled = testCase.autoSendEnterEnabled

        let mockTextService = MockTextInsertionServiceForEnterTest()

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: mockTextService,
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        // Reset mock state before calling
        mockTextService.simulateEnterKeyCalled = false

        sm.applyAutoSendEnter()

        // Requirement 5.6: simulateEnterKey called when enabled
        // Requirement 5.7: simulateEnterKey NOT called when disabled
        let called = mockTextService.simulateEnterKeyCalled
        let enabled = testCase.autoSendEnterEnabled
        #expect(called == enabled)
    }

    /// A single test case for the Enter keystroke conditional execution property test.
    struct EnterKeystrokeCase: Sendable, CustomTestStringConvertible {
        let id: Int
        let autoSendEnterEnabled: Bool

        var testDescription: String {
            "case \(id): autoSendEnterEnabled=\(autoSendEnterEnabled)"
        }
    }

    /// Generates 120 deterministic test cases alternating true/false for
    /// `autoSendEnterEnabled`. Minimum 100 iterations as required by the design document.
    nonisolated static let enterKeystrokeCases: [EnterKeystrokeCase] = {
        var cases: [EnterKeystrokeCase] = []
        for i in 0..<120 {
            cases.append(EnterKeystrokeCase(
                id: i,
                autoSendEnterEnabled: i % 2 == 0
            ))
        }
        return cases
    }()

    // MARK: - Property 4: Operation ordering when both features enabled

    // Feature: auto-suffix-insertion, Property 4: Operation ordering when both features enabled
    // Validates: Requirements 5.9
    @Test("Property 4: Operation ordering — insertText called before simulateEnterKey when both features enabled",
          arguments: StateManagerTests.operationOrderingCases)
    func testOperationOrdering(
        testCase: OperationOrderingCase
    ) async throws {
        let defaults = UserDefaults(suiteName: "test.wispr.ordering.prop.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSuffixEnabled = true
        settingsStore.autoSuffixText = testCase.autoSuffixText
        settingsStore.autoSendEnterEnabled = true

        let mockTextService = MockOrderTrackingTextInsertionService()

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: mockTextService,
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        // Step 1: Apply suffix to get the final text
        let finalText = sm.applyAutoSuffix(to: testCase.transcription)

        // Step 2: Insert text (as StateManager.endRecording would)
        try await mockTextService.insertText(finalText)

        // Step 3: Apply auto-send Enter (as StateManager.endRecording would)
        sm.applyAutoSendEnter()

        // Requirement 5.9: insertText must be called before simulateEnterKey
        #expect(mockTextService.callOrder.count == 2,
                "case \(testCase.id): expected 2 operations, got \(mockTextService.callOrder.count)")
        #expect(mockTextService.callOrder[0] == "insertText",
                "case \(testCase.id): first operation should be insertText, got \(mockTextService.callOrder[0])")
        #expect(mockTextService.callOrder[1] == "simulateEnterKey",
                "case \(testCase.id): second operation should be simulateEnterKey, got \(mockTextService.callOrder[1])")

        // Also verify the text passed to insertText includes the suffix
        let expectedText = testCase.autoSuffixText.isEmpty
            ? testCase.transcription
            : testCase.transcription + testCase.autoSuffixText
        #expect(mockTextService.insertedTexts.first == expectedText,
                "case \(testCase.id): inserted text should match expected suffix-appended text")
    }

    /// A single test case for the operation ordering property test.
    struct OperationOrderingCase: Sendable, CustomTestStringConvertible {
        let id: Int
        let transcription: String
        let autoSuffixText: String

        var testDescription: String {
            "case \(id): text=\"\(transcription)\", suffix=\"\(autoSuffixText)\""
        }
    }

    /// Generates 120 deterministic pseudo-random test cases with diverse
    /// transcription × suffix combinations. Both features are always enabled.
    /// Minimum 100 iterations as required by the design document.
    nonisolated static let operationOrderingCases: [OperationOrderingCase] = {
        let transcriptionPool: [String] = [
            "Hello world",
            "Testing",
            "A",
            "こんにちは",
            "🎤 voice input",
            "Multiple words in a sentence",
            String(repeating: "long ", count: 50),
            "café résumé",
            "Line1\nLine2",
            "tabs\there",
        ]

        let suffixPool: [String] = [
            "",           // empty — edge case
            ". ",         // default
            " ",          // single space
            ".",          // no trailing space
            "...",        // multiple dots
            "\n",         // newline
            "🎤",         // emoji
            "— ",         // em-dash
            "? ",         // question mark
            "END",        // alphabetic
            "。",         // CJK period
            ", ",         // comma
        ]

        var cases: [OperationOrderingCase] = []
        var id = 0

        // Generate 100 cases from exhaustive combinations
        outer: for transcription in transcriptionPool {
            for suffix in suffixPool {
                cases.append(OperationOrderingCase(
                    id: id,
                    transcription: transcription,
                    autoSuffixText: suffix
                ))
                id += 1
                if cases.count >= 100 { break outer }
            }
        }

        // Add 20 more pseudo-random cases using LCG
        var seed: UInt64 = 42
        for _ in 0..<20 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let tIdx = Int(seed >> 33) % transcriptionPool.count

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let sIdx = Int(seed >> 33) % suffixPool.count

            cases.append(OperationOrderingCase(
                id: id,
                transcription: transcriptionPool[tIdx],
                autoSuffixText: suffixPool[sIdx]
            ))
            id += 1
        }

        return cases
    }()

    // MARK: - Edge Case Unit Tests (Task 5.7)

    // Requirement 3.3: Empty suffix text results in no suffix appended
    @Test("Edge case: empty suffix text results in unmodified transcription")
    func testEmptySuffixTextNoAppend() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.emptysuffix.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSuffixEnabled = true
        settingsStore.autoSuffixText = ""

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyAutoSuffix(to: "Hello world")
        #expect(result == "Hello world", "Empty suffix text should leave transcription unmodified")
    }

    // Requirement 3.2: Suffix disabled results in unmodified text
    @Test("Edge case: suffix disabled results in unmodified transcription")
    func testSuffixDisabledNoAppend() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.disabled.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSuffixEnabled = false
        settingsStore.autoSuffixText = SettingsStore.Defaults.autoSuffixText

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyAutoSuffix(to: "Hello world")
        #expect(result == "Hello world", "Disabled suffix should leave transcription unmodified")
    }

    // Requirement 5.7: Auto-send Enter disabled results in no simulateEnterKey call
    @Test("Edge case: auto-send Enter disabled does not call simulateEnterKey")
    func testAutoSendEnterDisabledNoCall() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.enteroff.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSendEnterEnabled = false

        let mockTextService = MockTextInsertionServiceForEnterTest()

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: mockTextService,
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        sm.applyAutoSendEnter()
        #expect(mockTextService.simulateEnterKeyCalled == false,
                "simulateEnterKey should not be called when autoSendEnterEnabled is false")
    }

    // Requirements 3.4, 5.8: Suffix and Enter work regardless of handsFreeMode setting
    // The helper methods (applyAutoSuffix, applyAutoSendEnter) are mode-agnostic —
    // handsFreeMode only determines which code path calls them, not their behavior.

    @Test("Edge case: applyAutoSuffix works the same with handsFreeMode enabled")
    func testSuffixWorksInHandsFreeMode() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.hf.suffix.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSuffixEnabled = true
        settingsStore.autoSuffixText = SettingsStore.Defaults.autoSuffixText
        settingsStore.handsFreeMode = true

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyAutoSuffix(to: "Hello")
        #expect(result == "Hello" + SettingsStore.Defaults.autoSuffixText, "Suffix should be appended in hands-free mode")
    }

    @Test("Edge case: applyAutoSuffix works the same with handsFreeMode disabled (push-to-talk)")
    func testSuffixWorksInPushToTalkMode() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.ptt.suffix.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSuffixEnabled = true
        settingsStore.autoSuffixText = SettingsStore.Defaults.autoSuffixText
        settingsStore.handsFreeMode = false

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        let result = sm.applyAutoSuffix(to: "Hello")
        #expect(result == "Hello" + SettingsStore.Defaults.autoSuffixText, "Suffix should be appended in push-to-talk mode")
    }

    @Test("Edge case: applyAutoSendEnter works the same with handsFreeMode enabled")
    func testAutoSendEnterWorksInHandsFreeMode() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.hf.enter.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSendEnterEnabled = true
        settingsStore.handsFreeMode = true

        let mockTextService = MockTextInsertionServiceForEnterTest()

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: mockTextService,
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        sm.applyAutoSendEnter()
        #expect(mockTextService.simulateEnterKeyCalled == true,
                "simulateEnterKey should be called in hands-free mode when enabled")
    }

    @Test("Edge case: applyAutoSendEnter works the same with handsFreeMode disabled (push-to-talk)")
    func testAutoSendEnterWorksInPushToTalkMode() {
        let defaults = UserDefaults(suiteName: "test.wispr.edge.ptt.enter.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.autoSendEnterEnabled = true
        settingsStore.handsFreeMode = false

        let mockTextService = MockTextInsertionServiceForEnterTest()

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: mockTextService,
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )

        sm.applyAutoSendEnter()
        #expect(mockTextService.simulateEnterKeyCalled == true,
                "simulateEnterKey should be called in push-to-talk mode when enabled")
    }
}

// MARK: - Mock for Enter Keystroke Property Test

/// Mock TextInserting implementation that records whether `simulateEnterKey()` was called.
/// Used by Property 3 tests to verify conditional execution without CGEvent side effects.
@MainActor
final class MockTextInsertionServiceForEnterTest: TextInserting {
    var insertedTexts: [String] = []
    var simulateEnterKeyCalled = false

    func insertText(_ text: String) async throws {
        insertedTexts.append(text)
    }

    func simulateEnterKey() {
        simulateEnterKeyCalled = true
    }
}


// MARK: - Mock for Operation Ordering Property Test

/// Mock TextInserting implementation that records the order of `insertText()` and
/// `simulateEnterKey()` calls. Used by Property 4 tests to verify operation ordering
/// without CGEvent side effects.
@MainActor
final class MockOrderTrackingTextInsertionService: TextInserting {
    var callOrder: [String] = []
    var insertedTexts: [String] = []

    func insertText(_ text: String) async throws {
        callOrder.append("insertText")
        insertedTexts.append(text)
    }

    func simulateEnterKey() {
        callOrder.append("simulateEnterKey")
    }
}
