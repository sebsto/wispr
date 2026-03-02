//
//  EndToEndIntegrationTests.swift
//  wispr
//
//  End-to-end integration tests wiring up real service instances.
//  Tests full recording flow, settings persistence across "restarts",
//  model management, onboarding completion, and error recovery.
//  Requirements: 13.1, 13.12, 10.5
//

import Testing
import Foundation
@testable import wispr

// MARK: - End-to-End Integration Tests

@MainActor
@Suite("End-to-End Integration Tests")
struct EndToEndIntegrationTests {

    // MARK: - Helpers

    /// Creates a full set of real service instances for integration testing.
    /// Each test gets its own isolated UserDefaults suite.
    private func createServices(
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
        let suiteName = "test.wispr.e2e.\(UUID().uuidString)"
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

    /// Creates an isolated UserDefaults suite for settings persistence tests.
    private func createIsolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "test.wispr.e2e.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, suiteName)
    }

    // MARK: - 1. Full Recording Flow Integration

    @Test("E2E: beginRecording transitions to recording or error with permissions")
    func testFullFlowBeginRecording() async {
        let services = createServices(permissionsGranted: true)
        let sm = services.stateManager

        #expect(sm.appState == .idle)

        // In test env, AVAudioEngine will fail (no real mic)
        // so we expect either .recording or .error
        await sm.beginRecording()

        let validState: Bool
        switch sm.appState {
        case .recording, .error:
            validState = true
        default:
            validState = false
        }
        #expect(validState, "State should be recording or error after beginRecording")
    }

    @Test("E2E: endRecording transitions through processing and back to idle")
    func testFullFlowEndRecording() async {
        let services = createServices(permissionsGranted: true)
        let sm = services.stateManager

        // Force into recording state (bypassing hardware)
        sm.appState = .recording

        await sm.endRecording()

        // Empty audio → resetToIdle
        #expect(sm.appState == .idle, "Should return to idle when audio is empty")
        #expect(sm.errorMessage == nil)
        #expect(sm.audioLevelStream == nil)
    }

    @Test("E2E: error messages are populated on failure")
    func testFullFlowErrorMessagePopulated() async {
        let services = createServices(permissionsGranted: false)
        let sm = services.stateManager

        // Attempt recording without permissions → error
        await sm.beginRecording()

        if case .error(let msg) = sm.appState {
            #expect(!msg.isEmpty, "Error message should not be empty")
        } else {
            Issue.record("Expected error state when permissions denied")
        }
        #expect(sm.errorMessage != nil, "errorMessage property should be set on failure")
    }

    @Test("E2E: full cycle idle → recording → endRecording → idle")
    func testFullCycleIdleToRecordingToIdle() async {
        let services = createServices(permissionsGranted: true)
        let sm = services.stateManager

        #expect(sm.appState == .idle)

        // Force recording (bypassing hardware)
        sm.appState = .recording
        #expect(sm.appState == .recording)

        // End recording → empty audio → idle
        await sm.endRecording()
        #expect(sm.appState == .idle)
    }

    // MARK: - 2. Settings Persistence Across "Restarts"

    @Test("E2E: hotkey settings persist across SettingsStore instances")
    func testHotkeySettingsPersistence() {
        let (defaults, _) = createIsolatedDefaults()

        // "First launch" — change hotkey
        let store1 = SettingsStore(defaults: defaults)
        store1.hotkeyKeyCode = 36      // Return key
        store1.hotkeyModifiers = 4096  // Command

        // "Restart" — create new SettingsStore with same defaults
        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.hotkeyKeyCode == 36, "Hotkey keyCode should persist across restarts")
        #expect(store2.hotkeyModifiers == 4096, "Hotkey modifiers should persist across restarts")
    }

    @Test("E2E: audio device UID persists across SettingsStore instances")
    func testAudioDeviceUIDPersistence() {
        let (defaults, _) = createIsolatedDefaults()

        let store1 = SettingsStore(defaults: defaults)
        store1.selectedAudioDeviceUID = "BuiltInMicrophoneDevice"

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.selectedAudioDeviceUID == "BuiltInMicrophoneDevice",
                "Audio device UID should persist across restarts")
    }

    @Test("E2E: active model name persists across SettingsStore instances")
    func testActiveModelNamePersistence() {
        let (defaults, _) = createIsolatedDefaults()

        let store1 = SettingsStore(defaults: defaults)
        store1.activeModelName = "small"

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.activeModelName == "small",
                "Active model name should persist across restarts")
    }

    @Test("E2E: language mode persists across SettingsStore instances")
    func testLanguageModePersistence() {
        let (defaults, _) = createIsolatedDefaults()

        let store1 = SettingsStore(defaults: defaults)
        store1.languageMode = .pinned(code: "ja")

        let store2 = SettingsStore(defaults: defaults)
        if case .pinned(let code) = store2.languageMode {
            #expect(code == "ja", "Pinned language code should persist")
        } else {
            Issue.record("Language mode should persist as pinned(ja)")
        }
    }

    @Test("E2E: onboarding completed flag persists across SettingsStore instances")
    func testOnboardingCompletedPersistence() {
        let (defaults, _) = createIsolatedDefaults()

        let store1 = SettingsStore(defaults: defaults)
        #expect(store1.onboardingCompleted == false, "Should start as false")
        store1.onboardingCompleted = true

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.onboardingCompleted == true,
                "Onboarding completed flag should persist across restarts")
    }

    @Test("E2E: all settings persist together across a simulated restart")
    func testAllSettingsPersistTogether() {
        let (defaults, _) = createIsolatedDefaults()

        // "First launch" — configure everything
        let store1 = SettingsStore(defaults: defaults)
        store1.hotkeyKeyCode = 42
        store1.hotkeyModifiers = 8192
        store1.selectedAudioDeviceUID = "external-mic-uid"
        store1.activeModelName = "medium"
        store1.languageMode = .specific(code: "de")
        store1.onboardingCompleted = true
        store1.onboardingLastStep = OnboardingStep.completion.rawValue

        // "Restart"
        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.hotkeyKeyCode == 42)
        #expect(store2.hotkeyModifiers == 8192)
        #expect(store2.selectedAudioDeviceUID == "external-mic-uid")
        #expect(store2.activeModelName == "medium")
        #expect(store2.onboardingCompleted == true)
        #expect(store2.onboardingLastStep == OnboardingStep.completion.rawValue)

        if case .specific(let code) = store2.languageMode {
            #expect(code == "de")
        } else {
            Issue.record("Language mode should persist as specific(de)")
        }
    }

    // MARK: - 3. Model Management Flow

    @Test("E2E: availableModels returns expected model list")
    func testModelManagementAvailableModels() async {
        let services = createServices()
        let models = await services.whisperService.availableModels()

        #expect(models.count == 5, "Should have 5 available models")

        let ids = models.map(\.id)
        #expect(ids.contains("tiny"))
        #expect(ids.contains("base"))
        #expect(ids.contains("small"))
        #expect(ids.contains("medium"))
        #expect(ids.contains("large-v3"))
    }

    @Test("E2E: modelStatus returns notDownloaded for undownloaded models")
    func testModelManagementStatusNotDownloaded() async {
        let services = createServices()
        // Use a model name that definitely won't exist on disk
        let status = await services.whisperService.modelStatus("nonexistent-model-xyz")

        if case .notDownloaded = status {
            // Expected
        } else {
            Issue.record("Expected .notDownloaded status for undownloaded model, got \(status)")
        }
    }

    @Test("E2E: activeModel returns nil initially")
    func testModelManagementActiveModelNil() async {
        let services = createServices()
        let active = await services.whisperService.activeModel()

        #expect(active == nil, "No model should be active initially")
    }

    @Test("E2E: transcribe without loaded model throws appropriate error")
    func testModelManagementTranscribeWithoutModel() async {
        let services = createServices()
        let audioData: [Float] = [Float](repeating: 0, count: 500)

        do {
            _ = try await services.whisperService.transcribe(audioData, language: .autoDetect)
            Issue.record("Expected transcribe to throw when no model is loaded")
        } catch let error as WisprError {
            if case .modelNotDownloaded = error {
                // Expected — correct error for no loaded model
            } else {
                Issue.record("Expected modelNotDownloaded error, got \(error)")
            }
        } catch {
            Issue.record("Expected WisprError, got \(error)")
        }
    }

    // MARK: - 4. Onboarding Completion Flow

    @Test("E2E: onboardingCompleted starts as false")
    func testOnboardingStartsFalse() {
        let (defaults, _) = createIsolatedDefaults()
        let store = SettingsStore(defaults: defaults)

        #expect(store.onboardingCompleted == false, "Onboarding should start as not completed")
    }

    @Test("E2E: setting onboardingCompleted to true persists")
    func testOnboardingCompletedPersists() {
        let (defaults, _) = createIsolatedDefaults()

        let store1 = SettingsStore(defaults: defaults)
        store1.onboardingCompleted = true

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.onboardingCompleted == true,
                "onboardingCompleted = true should persist across instances")
    }

    @Test("E2E: onboardingLastStep persists correctly for resume")
    func testOnboardingLastStepPersists() {
        let (defaults, _) = createIsolatedDefaults()

        let store1 = SettingsStore(defaults: defaults)
        #expect(store1.onboardingLastStep == 0, "Should start at step 0")

        store1.onboardingLastStep = OnboardingStep.modelSelection.rawValue

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.onboardingLastStep == OnboardingStep.modelSelection.rawValue,
                "onboardingLastStep should persist for resume on next launch")
    }

    // MARK: - 5. Error Recovery Integration

    @Test("E2E: handleError transitions to error state with message")
    func testErrorRecoveryHandleError() async {
        let services = createServices()
        let sm = services.stateManager

        #expect(sm.appState == .idle)

        await sm.handleError(.noAudioDeviceAvailable)

        if case .error(let msg) = sm.appState {
            #expect(!msg.isEmpty, "Error message should not be empty")
        } else {
            Issue.record("Expected error state after handleError")
        }
        #expect(sm.errorMessage != nil)
    }

    @Test("E2E: resetToIdle returns to idle and clears error")
    func testErrorRecoveryResetToIdle() async {
        let services = createServices()
        let sm = services.stateManager

        await sm.handleError(.transcriptionFailed("test failure"))
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state")
        }
        #expect(sm.errorMessage != nil)

        await sm.resetToIdle()

        #expect(sm.appState == .idle, "Should return to idle after reset")
        #expect(sm.errorMessage == nil, "Error message should be cleared after reset")
    }

    @Test("E2E: multiple rapid state transitions don't cause crashes")
    func testErrorRecoveryRapidTransitions() async {
        let services = createServices(permissionsGranted: true)
        let sm = services.stateManager

        // Rapid error → reset cycles
        for i in 0..<10 {
            await sm.handleError(.audioRecordingFailed("error \(i)"))
            if case .error = sm.appState {} else {
                Issue.record("Should be in error state at iteration \(i)")
            }
            await sm.resetToIdle()
            #expect(sm.appState == .idle, "Should be idle after reset at iteration \(i)")
        }

        // Rapid state changes mixing different transitions
        sm.appState = .recording
        await sm.endRecording()
        #expect(sm.appState == .idle)

        await sm.handleError(.modelNotDownloaded)
        await sm.resetToIdle()
        #expect(sm.appState == .idle)

        sm.appState = .processing
        await sm.resetToIdle()
        #expect(sm.appState == .idle, "Should handle rapid mixed transitions without crashing")
    }

    @Test("E2E: error → reset → beginRecording cycle works")
    func testErrorRecoveryCycleToRecording() async {
        let services = createServices(permissionsGranted: true)
        let sm = services.stateManager

        // Error
        await sm.handleError(.audioDeviceDisconnected)
        if case .error = sm.appState {} else {
            Issue.record("Should be in error state")
        }

        // Reset
        await sm.resetToIdle()
        #expect(sm.appState == .idle)

        // Attempt recording again
        await sm.beginRecording()

        let validState: Bool
        switch sm.appState {
        case .recording, .error:
            validState = true
        default:
            validState = false
        }
        #expect(validState, "Should be able to attempt recording after error recovery")
    }
}
