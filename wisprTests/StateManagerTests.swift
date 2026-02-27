//
//  StateManagerTests.swift
//  wispr
//
//  Unit tests for StateManager state machine logic.
//  Requirements: 12.1, 12.5
//

import Testing
import Foundation
@testable import wispr

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
        hotkeyMonitor: hotkeyMonitor,
        permissionManager: permissionManager,
        settingsStore: settingsStore
    )

    return (stateManager, permissionManager)
}

// MARK: - Tests

@MainActor
@Suite("StateManager Tests")
struct StateManagerTests {

    // MARK: - Initial State

    @Test("StateManager starts in idle state")
    func testInitialState() {
        let (sm, _) = createTestStateManager()
        #expect(sm.appState == .idle)
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

    @Test("beginRecording is ignored when in error state")
    func testConcurrentRecordingPreventionWhileError() async {
        let (sm, _) = createTestStateManager(permissionsGranted: true)

        // Force state to error
        sm.appState = .error("some error")

        await sm.beginRecording()

        // Should remain in error state
        if case .error = sm.appState {
            // Expected
        } else {
            Issue.record("State should remain in error")
        }
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
}
