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
        
        // General defaults (launchAtLogin reads from SMAppService.mainApp.status, not UserDefaults)
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
        store.onboardingCompleted = true
        store.onboardingLastStep = 3

        // Create a new store instance to verify persistence
        let newStore = SettingsStore(defaults: defaults)

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
    
    // MARK: - Sound Feedback Tests

    @Test("SettingsStore soundFeedbackEnabled defaults to false")
    func testSoundFeedbackDefault() {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.soundFeedbackEnabled == false)
    }

    @Test("SettingsStore persists soundFeedbackEnabled")
    func testSoundFeedbackPersistence() {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.soundFeedbackEnabled = true

        let newStore = SettingsStore(defaults: defaults)
        #expect(newStore.soundFeedbackEnabled == true, "soundFeedbackEnabled should persist")
    }

    // MARK: - Filler Word Removal Tests

    @Test("SettingsStore removeFillerWords defaults to false")
    func testRemoveFillerWordsDefault() {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        #expect(store.removeFillerWords == false)
    }

    @Test("SettingsStore persists removeFillerWords")
    func testRemoveFillerWordsPersistence() {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.removeFillerWords = true

        let newStore = SettingsStore(defaults: defaults)
        #expect(newStore.removeFillerWords == true, "removeFillerWords should persist")
    }

    @Test("SettingsStore restoreDefaults resets removeFillerWords to false")
    func testRestoreDefaultsResetsRemoveFillerWords() {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)
        store.removeFillerWords = true
        store.restoreDefaults()
        #expect(store.removeFillerWords == false)
    }

    // MARK: - Property-Based Tests

    // Feature: auto-suffix-insertion, Property 1: Settings persistence round-trip
    // Validates: Requirements 1.3, 1.4, 5.2
    @Test("Property 1: Settings persistence round-trip — auto-suffix and auto-send Enter values survive a write→reload cycle",
          arguments: SettingsStoreTests.settingsRoundTripCases)
    func testSettingsPersistenceRoundTrip(
        testCase: SettingsRoundTripCase
    ) async {
        let defaults = createTestDefaults()
        let store = SettingsStore(defaults: defaults)

        // Write random values
        store.autoSuffixEnabled = testCase.autoSuffixEnabled
        store.autoSuffixText = testCase.autoSuffixText
        store.autoSendEnterEnabled = testCase.autoSendEnterEnabled

        // Create a fresh instance from the same UserDefaults
        let reloaded = SettingsStore(defaults: defaults)

        #expect(reloaded.autoSuffixEnabled == testCase.autoSuffixEnabled,
                "autoSuffixEnabled should survive round-trip (iteration \(testCase.id))")
        #expect(reloaded.autoSuffixText == testCase.autoSuffixText,
                "autoSuffixText should survive round-trip (iteration \(testCase.id))")
        #expect(reloaded.autoSendEnterEnabled == testCase.autoSendEnterEnabled,
                "autoSendEnterEnabled should survive round-trip (iteration \(testCase.id))")
    }

    /// A single test case for the settings persistence round-trip property test.
    struct SettingsRoundTripCase: Sendable, CustomTestStringConvertible {
        let id: Int
        let autoSuffixEnabled: Bool
        let autoSendEnterEnabled: Bool
        let autoSuffixText: String

        var testDescription: String {
            "case \(id): enabled=\(autoSuffixEnabled), enter=\(autoSendEnterEnabled), text=\"\(autoSuffixText)\""
        }
    }

    /// Generates 120 deterministic pseudo-random test cases covering diverse
    /// Bool × Bool × String combinations for the round-trip property test.
    /// Minimum 100 iterations as required by the design document.
    nonisolated static let settingsRoundTripCases: [SettingsRoundTripCase] = {
        // Curated suffix strings that exercise interesting edge cases:
        // empty, whitespace-only, default value, unicode, long strings, special chars
        let suffixPool: [String] = [
            "",                     // empty string edge case
            ". ",                   // period + space
            " ",                    // single space
            ".",                    // no trailing space
            "...",                  // multiple dots
            "\n",                   // newline
            "\t",                   // tab
            "🎤",                   // emoji
            "— ",                   // em-dash + space
            "? ",                   // question mark
            "! ",                   // exclamation
            "; ",                   // semicolon
            ", ",                   // comma
            "END",                  // alphabetic
            "  ",                   // double space
            "。",                   // CJK period
            "\r\n",                 // CRLF
            "abc123!@#",           // mixed alphanumeric + symbols
            String(repeating: "x", count: 200), // long string
            "café résumé naïve",   // accented characters
        ]

        var cases: [SettingsRoundTripCase] = []
        var id = 0

        // Exhaustive Bool × Bool = 4 combos, cycled across all suffix strings
        let boolCombos: [(Bool, Bool)] = [
            (false, false), (false, true), (true, false), (true, true)
        ]

        // First pass: 4 bool combos × 20 strings = 80 cases
        for combo in boolCombos {
            for suffix in suffixPool {
                cases.append(SettingsRoundTripCase(
                    id: id,
                    autoSuffixEnabled: combo.0,
                    autoSendEnterEnabled: combo.1,
                    autoSuffixText: suffix
                ))
                id += 1
            }
        }

        // Second pass: 40 more cases with seeded pseudo-random selection to reach 120
        // Uses a simple LCG for deterministic reproducibility
        var seed: UInt64 = 42
        for _ in 0..<40 {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let suffixIndex = Int(seed >> 33) % suffixPool.count

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let enabledBit = (seed >> 33) % 2 == 0

            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let enterBit = (seed >> 33) % 2 == 0

            cases.append(SettingsRoundTripCase(
                id: id,
                autoSuffixEnabled: enabledBit,
                autoSendEnterEnabled: enterBit,
                autoSuffixText: suffixPool[suffixIndex]
            ))
            id += 1
        }

        return cases
    }()

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
