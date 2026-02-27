//
//  SettingsStoreTests.swift
//  wispr
//
//  Unit tests for SettingsStore using swift-testing framework
//

import Testing
import Foundation
@testable import wispr

@MainActor
@Suite("SettingsStore Tests")
struct SettingsStoreTests {
    
    // MARK: - Test Helpers
    
    /// Creates a test-specific UserDefaults suite for isolation
    func createTestDefaults() -> UserDefaults {
        let suiteName = "test.wispr.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return defaults
    }
    
    /// Clears all UserDefaults keys used by SettingsStore
    func clearDefaults(_ defaults: UserDefaults) {
        let keys = [
            "hotkeyKeyCode",
            "hotkeyModifiers",
            "selectedAudioDeviceUID",
            "activeModelName",
            "languageMode",
            "launchAtLogin",
            "onboardingCompleted",
            "onboardingLastStep"
        ]
        
        for key in keys {
            defaults.removeObject(forKey: key)
        }
        defaults.synchronize()
    }
    
    // MARK: - Default Values Tests
    
    @Test("SettingsStore initializes with correct default values")
    func testDefaultValues() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Hotkey defaults
        #expect(store.hotkeyKeyCode == 49, "Default hotkey key code should be 49 (Space)")
        #expect(store.hotkeyModifiers == 2048, "Default hotkey modifiers should be 2048 (Option)")
        
        // Audio defaults
        #expect(store.selectedAudioDeviceUID == nil, "Default audio device UID should be nil")
        
        // Model defaults
        #expect(store.activeModelName == "tiny", "Default model should be tiny")
        
        // Language defaults
        if case .autoDetect = store.languageMode {
            // Success
        } else {
            Issue.record("Default language mode should be autoDetect")
        }
        
        // General defaults
        #expect(store.launchAtLogin == false, "Launch at login should default to false")
        #expect(store.onboardingCompleted == false, "Onboarding completed should default to false")
        #expect(store.onboardingLastStep == 0, "Onboarding last step should default to 0")
    }
    
    // MARK: - Persistence Tests
    
    @Test("SettingsStore persists hotkey settings")
    func testHotkeyPersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Modify hotkey settings
        store.hotkeyKeyCode = 42
        store.hotkeyModifiers = 4096
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        #expect(newStore.hotkeyKeyCode == 42, "Hotkey key code should persist")
        #expect(newStore.hotkeyModifiers == 4096, "Hotkey modifiers should persist")
    }
    
    @Test("SettingsStore persists audio device selection")
    func testAudioDevicePersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Set audio device
        store.selectedAudioDeviceUID = "test-device-uid-123"
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        #expect(newStore.selectedAudioDeviceUID == "test-device-uid-123", "Audio device UID should persist")
    }
    
    @Test("SettingsStore persists model selection")
    func testModelPersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Change model
        store.activeModelName = "base"
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        #expect(newStore.activeModelName == "base", "Active model name should persist")
    }
    
    @Test("SettingsStore persists language mode - autoDetect")
    func testLanguageModeAutoDetectPersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Set to autoDetect
        store.languageMode = .autoDetect
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        if case .autoDetect = newStore.languageMode {
            // Success
        } else {
            Issue.record("Language mode autoDetect should persist")
        }
    }
    
    @Test("SettingsStore persists language mode - specific language")
    func testLanguageModeSpecificPersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Set to specific language
        store.languageMode = .specific(code: "en")
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        if case .specific(let code) = newStore.languageMode {
            #expect(code == "en", "Specific language code should persist")
        } else {
            Issue.record("Language mode specific should persist")
        }
    }
    
    @Test("SettingsStore persists language mode - pinned language")
    func testLanguageModePinnedPersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Set to pinned language
        store.languageMode = .pinned(code: "fr")
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        if case .pinned(let code) = newStore.languageMode {
            #expect(code == "fr", "Pinned language code should persist")
        } else {
            Issue.record("Language mode pinned should persist")
        }
    }
    
    @Test("SettingsStore persists general settings")
    func testGeneralSettingsPersistence() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Modify general settings
        store.launchAtLogin = true
        store.onboardingCompleted = true
        store.onboardingLastStep = 3
        
        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)
        
        #expect(newStore.launchAtLogin == true, "Launch at login should persist")
        #expect(newStore.onboardingCompleted == true, "Onboarding completed should persist")
        #expect(newStore.onboardingLastStep == 3, "Onboarding last step should persist")
    }
    
    // MARK: - Save/Load Tests
    
    @Test("SettingsStore save() persists all properties")
    func testSaveMethod() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Modify all properties
        store.hotkeyKeyCode = 50
        store.hotkeyModifiers = 8192
        store.selectedAudioDeviceUID = "device-123"
        store.activeModelName = "medium"
        store.languageMode = .specific(code: "es")
        store.launchAtLogin = true
        store.onboardingCompleted = true
        store.onboardingLastStep = 5
        
        // Explicitly call save (though didSet should have called it)
        store.save()
        
        // Verify persistence by creating new store
        let newStore = SettingsStore(defaults: defaults)
        
        #expect(newStore.hotkeyKeyCode == 50)
        #expect(newStore.hotkeyModifiers == 8192)
        #expect(newStore.selectedAudioDeviceUID == "device-123")
        #expect(newStore.activeModelName == "medium")
        #expect(newStore.launchAtLogin == true)
        #expect(newStore.onboardingCompleted == true)
        #expect(newStore.onboardingLastStep == 5)
        
        if case .specific(let code) = newStore.languageMode {
            #expect(code == "es")
        } else {
            Issue.record("Language mode should persist as specific(es)")
        }
    }
    
    @Test("SettingsStore load() retrieves persisted values")
    func testLoadMethod() async {
        let defaults = createTestDefaults()
        
        // First, create a store and set values
        let store1 = SettingsStore(defaults: defaults)
        store1.hotkeyKeyCode = 55
        store1.activeModelName = "large-v3"
        store1.save()
        
        // Create a new store and verify it loads the values
        let store2 = SettingsStore(defaults: defaults)
        
        #expect(store2.hotkeyKeyCode == 55, "load() should retrieve persisted hotkey key code")
        #expect(store2.activeModelName == "large-v3", "load() should retrieve persisted model name")
    }
    
    // MARK: - Edge Cases
    
    @Test("SettingsStore handles nil audio device UID")
    func testNilAudioDeviceUID() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Set to non-nil
        store.selectedAudioDeviceUID = "device-abc"
        
        // Set back to nil
        store.selectedAudioDeviceUID = nil
        
        // Create new store to verify nil persists
        let newStore = SettingsStore(defaults: defaults)
        
        #expect(newStore.selectedAudioDeviceUID == nil, "Nil audio device UID should persist")
    }
    
    @Test("SettingsStore handles multiple rapid changes")
    func testRapidChanges() async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        
        // Make multiple rapid changes
        for i in 0..<10 {
            store.onboardingLastStep = i
        }
        
        // Verify final value persists
        let newStore = SettingsStore(defaults: defaults)
        #expect(newStore.onboardingLastStep == 9, "Final value should persist after rapid changes")
    }
}
