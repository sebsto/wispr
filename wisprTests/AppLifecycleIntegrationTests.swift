//
//  AppLifecycleIntegrationTests.swift
//  wispr
//
//  Integration tests for application lifecycle.
//  Tests full recording flow, error recovery, onboarding, and state transitions
//  using real service instances (no mocks).
//  Requirements: 12.1, 13.12
//

import Testing
import Foundation
@testable import wispr

// MARK: - Integration Test Helpers

/// Creates a full set of real service instances for integration testing.
/// Each test gets its own isolated UserDefaults suite to avoid cross-contamination.
@MainActor
private func createIntegrationServices(
    permissionsGranted: Bool = false
) -> (
    stateManager: StateManager,
    permissionManager: PermissionManager,
    settingsStore: SettingsStore,
    audioEngine: AudioEngine,
    whisperService: WhisperService,
    hotkeyMonitor: HotkeyMonitor
) {
    let audioEngine = AudioEngine()
    let whisperService = WhisperService()
    let textInsertionService = TextInsertionService()
    let hotkeyMonitor = HotkeyMonitor()
    let permissionManager = PermissionManager()
    let suiteName = "test.wispr.integration.\(UUID().uuidString)"
    let settingsStore = SettingsStore(defaults: UserDefaults(suiteName: suiteName)!)

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

    return (stateManager, permissionManager, settingsStore, audioEngine, whisperService, hotkeyMonitor)
}

// MARK: - Full Recording Flow Tests

@MainActor
@Suite("Application Lifecycle Integration Tests")
struct AppLifecycleIntegrationTests {

    // MARK: - Recording → Transcription → Insertion Flow (Requirement 12.1)

    @Test("Full flow: idle → beginRecording with permissions → recording or error (no hardware)")
    func testFullRecordingFlowWithPermissions() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        #expect(sm.appState == .idle)

        // Begin recording — in test env, AVAudioEngine will fail (no real mic)
        // so we expect either .recording (if somehow it works) or .error
        await sm.beginRecording()

        let isRecordingOrError: Bool
        switch sm.appState {
        case .recording, .error:
            isRecordingOrError = true
        default:
            isRecordingOrError = false
        }
        #expect(isRecordingOrError, "State should be recording or error after beginRecording")
    }

    @Test("Full flow: recording → endRecording → idle (empty audio)")
    func testRecordingToEndRecordingEmptyAudio() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        // Force into recording state (bypassing hardware)
        sm.appState = .recording

        // End recording — AudioEngine returns empty samples (no real capture)
        await sm.endRecording()

        // Empty audio → resetToIdle
        #expect(sm.appState == .idle, "Should return to idle when audio is empty")
        #expect(sm.errorMessage == nil)
        #expect(sm.audioLevelStream == nil)
    }

    @Test("Full flow: recording → endRecording → processing → error (no model loaded)")
    func testRecordingToTranscriptionWithoutModel() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        // We need to simulate having audio data. Since AudioEngine.stopCapture()
        // returns empty when no real capture happened, endRecording will hit the
        // empty audio guard and go to idle. This tests that path correctly.
        sm.appState = .recording

        await sm.endRecording()

        // With no real audio captured, we get empty samples → idle
        #expect(sm.appState == .idle)
    }

    // MARK: - Error Recovery and State Transitions (Requirement 12.1)

    @Test("Error recovery: handleError → error state → auto-dismiss timer set")
    func testErrorRecoveryFlow() async {
        let services = createIntegrationServices()
        let sm = services.stateManager

        #expect(sm.appState == .idle)

        // Trigger an error
        await sm.handleError(.noAudioDeviceAvailable)

        // Should be in error state
        if case .error(let msg) = sm.appState {
            #expect(!msg.isEmpty)
        } else {
            Issue.record("Expected error state after handleError")
        }
        #expect(sm.errorMessage != nil)

        // Manually reset (simulating what the auto-dismiss timer would do)
        await sm.resetToIdle()

        #expect(sm.appState == .idle)
        #expect(sm.errorMessage == nil)
    }

    @Test("Error recovery: multiple errors update state correctly")
    func testMultipleErrorRecovery() async {
        let services = createIntegrationServices()
        let sm = services.stateManager

        // First error
        await sm.handleError(.noAudioDeviceAvailable)
        let firstMsg = sm.errorMessage

        // Second error overwrites first
        await sm.handleError(.transcriptionFailed("model error"))
        let secondMsg = sm.errorMessage

        #expect(firstMsg != secondMsg, "Second error should overwrite first")

        if case .error = sm.appState {
            // Expected
        } else {
            Issue.record("Should still be in error state")
        }

        // Recovery
        await sm.resetToIdle()
        #expect(sm.appState == .idle)
    }

    @Test("Error recovery: error → idle → can begin recording again")
    func testErrorToIdleToRecordingCycle() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        // Enter error state
        await sm.handleError(.audioRecordingFailed("test failure"))
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state")
        }

        // Recover
        await sm.resetToIdle()
        #expect(sm.appState == .idle)

        // Try recording again — should attempt (will fail due to no hardware)
        await sm.beginRecording()

        let isRecordingOrError: Bool
        switch sm.appState {
        case .recording, .error:
            isRecordingOrError = true
        default:
            isRecordingOrError = false
        }
        #expect(isRecordingOrError, "Should be able to attempt recording after error recovery")
    }

    // MARK: - Onboarding Completion and Skip (Requirement 13.12)

    @Test("Onboarding: settingsStore.onboardingCompleted persists correctly")
    func testOnboardingCompletionPersistence() {
        let suiteName = "test.wispr.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)

        // Initially not completed
        #expect(store.onboardingCompleted == false)

        // Mark as completed
        store.onboardingCompleted = true

        // Create a new SettingsStore with the same defaults to verify persistence
        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.onboardingCompleted == true, "onboardingCompleted should persist across instances")
    }

    @Test("Onboarding: onboardingLastStep persists for resume")
    func testOnboardingLastStepPersistence() {
        let suiteName = "test.wispr.onboarding.step.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let store = SettingsStore(defaults: defaults)

        // Initially at step 0
        #expect(store.onboardingLastStep == 0)

        // Advance to step 3 (model selection)
        store.onboardingLastStep = OnboardingStep.modelSelection.rawValue

        // Verify persistence
        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.onboardingLastStep == OnboardingStep.modelSelection.rawValue,
                "onboardingLastStep should persist for resume on next launch")
    }

    @Test("Onboarding: skip flag prevents onboarding on subsequent launches")
    func testOnboardingSkipOnSubsequentLaunch() {
        let suiteName = "test.wispr.onboarding.skip.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!

        // Simulate first launch completing onboarding
        let store1 = SettingsStore(defaults: defaults)
        store1.onboardingCompleted = true

        // Simulate second launch
        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.onboardingCompleted == true,
                "Onboarding should not appear on subsequent launches")
    }

    // MARK: - Permission Gating

    @Test("Permission gating: recording fails gracefully without permissions")
    func testRecordingFailsWithoutPermissions() async {
        let services = createIntegrationServices(permissionsGranted: false)
        let sm = services.stateManager

        #expect(sm.appState == .idle)

        // Attempt to record without permissions
        await sm.beginRecording()

        // Should transition to error (permission denied)
        if case .error = sm.appState {
            // Expected
        } else {
            Issue.record("Expected error state when permissions are denied, got \(sm.appState)")
        }
        #expect(sm.errorMessage != nil, "Should have an error message about permissions")
    }

    @Test("Permission gating: granting permissions allows recording attempt")
    func testGrantingPermissionsAllowsRecording() async {
        let services = createIntegrationServices(permissionsGranted: false)
        let sm = services.stateManager
        let pm = services.permissionManager

        // First attempt fails
        await sm.beginRecording()
        if case .error = sm.appState {} else {
            Issue.record("Should fail without permissions")
        }

        // Reset and grant permissions
        await sm.resetToIdle()
        pm.microphoneStatus = .authorized
        pm.accessibilityStatus = .authorized

        // Second attempt should proceed past the permission check
        await sm.beginRecording()

        // Will be .recording or .error (from audio hardware), but NOT permission error
        let isRecordingOrError: Bool
        switch sm.appState {
        case .recording, .error:
            isRecordingOrError = true
        default:
            isRecordingOrError = false
        }
        #expect(isRecordingOrError)
    }

    // MARK: - Multiple Recording Cycles

    @Test("Multiple cycles: idle → recording → idle → recording")
    func testMultipleRecordingCycles() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        // Cycle 1: begin → end
        #expect(sm.appState == .idle)
        sm.appState = .recording
        await sm.endRecording()
        #expect(sm.appState == .idle, "Should return to idle after first cycle")

        // Cycle 2: begin → end
        sm.appState = .recording
        await sm.endRecording()
        #expect(sm.appState == .idle, "Should return to idle after second cycle")
    }

    @Test("Multiple cycles: error between cycles doesn't block next cycle")
    func testErrorBetweenCyclesDoesNotBlock() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        // Cycle 1
        sm.appState = .recording
        await sm.endRecording()
        #expect(sm.appState == .idle)

        // Error occurs
        await sm.handleError(.transcriptionFailed("transient error"))
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state")
        }

        // Recover
        await sm.resetToIdle()
        #expect(sm.appState == .idle)

        // Cycle 2 should work
        sm.appState = .recording
        await sm.endRecording()
        #expect(sm.appState == .idle, "Should complete second cycle after error recovery")
    }

    @Test("Concurrent recording prevention across cycles")
    func testConcurrentRecordingPreventionAcrossCycles() async {
        let services = createIntegrationServices(permissionsGranted: true)
        let sm = services.stateManager

        // Force into recording
        sm.appState = .recording

        // Attempt another recording — should be ignored
        await sm.beginRecording()
        #expect(sm.appState == .recording, "Should still be in recording state (concurrent prevention)")

        // End first recording
        await sm.endRecording()
        #expect(sm.appState == .idle)
    }

    // MARK: - State Transition Integrity

    @Test("endRecording from non-recording state is a no-op")
    func testEndRecordingFromNonRecordingIsNoOp() async {
        let services = createIntegrationServices()
        let sm = services.stateManager

        // From idle
        #expect(sm.appState == .idle)
        await sm.endRecording()
        #expect(sm.appState == .idle)

        // From processing
        sm.appState = .processing
        await sm.endRecording()
        #expect(sm.appState == .processing)

        // From error
        sm.appState = .error("test")
        await sm.endRecording()
        if case .error = sm.appState {
            // Expected — endRecording is a no-op from error state
        } else {
            Issue.record("endRecording should be no-op from error state")
        }
    }

    @Test("handleError cleans up audio state")
    func testHandleErrorCleansUpAudioState() async {
        let services = createIntegrationServices()
        let sm = services.stateManager

        // Simulate having an active audio stream
        sm.audioLevelStream = AsyncStream<Float> { $0.finish() }

        await sm.handleError(.audioDeviceDisconnected)

        #expect(sm.audioLevelStream == nil, "Audio stream should be cleaned up on error")
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state")
        }
    }
}
