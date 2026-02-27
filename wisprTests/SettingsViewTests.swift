//
//  SettingsViewTests.swift
//  wispr
//
//  Unit tests for SettingsView logic: language mode transitions, hotkey display
//  string formatting, settings persistence, and supported languages list.
//  Requirements: 10.5, 17.2, 17.8
//

import Testing
import Foundation
import Carbon
@testable import wispr

// MARK: - Language Mode Transition Tests

/// Tests the language mode binding logic from SettingsView.
/// Validates: Requirements 16.3, 16.4, 16.5, 16.10, 16.11
@MainActor
@Suite("SettingsView Language Mode Transitions")
struct SettingsViewLanguageModeTests {

    /// Creates a SettingsStore backed by an isolated UserDefaults suite.
    private func makeStore() -> SettingsStore {
        SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.settings.\(UUID().uuidString)")!
        )
    }

    // MARK: - Auto-Detect ↔ Specific

    @Test("Disabling auto-detect defaults to specific English")
    func testAutoDetectToSpecific() {
        let store = makeStore()
        #expect(store.languageMode == .autoDetect)

        // Simulate the autoDetectBinding set(false) path
        store.languageMode = .specific(code: "en")

        #expect(store.languageMode == .specific(code: "en"))
        #expect(store.languageMode.isAutoDetect == false)
        #expect(store.languageMode.languageCode == "en")
    }

    @Test("Enabling auto-detect from specific clears language selection")
    func testSpecificToAutoDetect() {
        let store = makeStore()
        store.languageMode = .specific(code: "fr")

        // Simulate the autoDetectBinding set(true) path
        store.languageMode = .autoDetect

        #expect(store.languageMode.isAutoDetect == true)
        #expect(store.languageMode.languageCode == nil)
    }

    // MARK: - Specific ↔ Pinned

    @Test("Pinning a specific language transitions to pinned mode")
    func testSpecificToPinned() {
        let store = makeStore()
        store.languageMode = .specific(code: "de")

        // Simulate the pinLanguageBinding set(true) path
        let code = store.languageMode.languageCode ?? "en"
        store.languageMode = .pinned(code: code)

        #expect(store.languageMode.isPinned == true)
        #expect(store.languageMode.languageCode == "de")
    }

    @Test("Unpinning a language transitions back to specific mode")
    func testPinnedToSpecific() {
        let store = makeStore()
        store.languageMode = .pinned(code: "ja")

        // Simulate the pinLanguageBinding set(false) path
        let code = store.languageMode.languageCode ?? "en"
        store.languageMode = .specific(code: code)

        #expect(store.languageMode.isPinned == false)
        #expect(store.languageMode == .specific(code: "ja"))
    }

    // MARK: - Pinned → Auto-Detect (Requirement 16.11)

    @Test("Enabling auto-detect from pinned clears pinned language")
    func testPinnedToAutoDetect() {
        let store = makeStore()
        store.languageMode = .pinned(code: "es")

        // Simulate the autoDetectBinding set(true) path
        store.languageMode = .autoDetect

        #expect(store.languageMode.isAutoDetect == true)
        #expect(store.languageMode.isPinned == false)
        #expect(store.languageMode.languageCode == nil)
    }

    // MARK: - Language Code Change While Pinned

    @Test("Changing language code while pinned preserves pinned state")
    func testChangeLanguageWhilePinned() {
        let store = makeStore()
        store.languageMode = .pinned(code: "fr")

        // Simulate the selectedLanguageCodeBinding set path when pinned
        let isPinned = store.languageMode.isPinned
        if isPinned {
            store.languageMode = .pinned(code: "ko")
        }

        #expect(store.languageMode.isPinned == true)
        #expect(store.languageMode.languageCode == "ko")
    }

    @Test("Changing language code while specific preserves specific state")
    func testChangeLanguageWhileSpecific() {
        let store = makeStore()
        store.languageMode = .specific(code: "en")

        // Simulate the selectedLanguageCodeBinding set path when not pinned
        let isPinned = store.languageMode.isPinned
        if !isPinned {
            store.languageMode = .specific(code: "zh")
        }

        #expect(store.languageMode.isPinned == false)
        #expect(store.languageMode.languageCode == "zh")
    }
}

// MARK: - Hotkey Display String Tests

/// Tests the hotkey display string formatting logic from HotkeyRecorderView.
/// Validates: Requirement 10.1
@MainActor
@Suite("SettingsView Hotkey Display String")
struct SettingsViewHotkeyDisplayTests {

    /// Mirrors the `hotkeyDisplayString` logic from HotkeyRecorderView.
    private func hotkeyDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        var parts: [String] = []

        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        let keyName = keyCodeToString(keyCode)
        parts.append(keyName)

        return parts.joined()
    }

    /// Mirrors the `keyCodeToString` function from HotkeyRecorderView.
    private func keyCodeToString(_ code: UInt32) -> String {
        let keyNames: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
            30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 37: "L",
            38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",", 44: "/",
            45: "N", 46: "M", 47: ".", 49: "Space", 36: "Return", 48: "Tab",
            51: "Delete", 53: "Escape", 76: "Enter", 96: "F5", 97: "F6",
            98: "F7", 99: "F3", 100: "F8", 101: "F9", 103: "F11", 105: "F13",
            109: "F10", 111: "F12", 113: "F14", 115: "Home", 116: "PageUp",
            117: "Forward Delete", 118: "F4", 119: "End", 120: "F2",
            121: "PageDown", 122: "F1", 123: "←", 124: "→", 125: "↓", 126: "↑",
        ]
        return keyNames[code] ?? "Key \(code)"
    }

    @Test("Default hotkey displays as ⌥Space")
    func testDefaultHotkey() {
        // Default: keyCode 49 (Space), modifiers 2048 (Option)
        let display = hotkeyDisplayString(keyCode: 49, modifiers: UInt32(optionKey))
        #expect(display == "⌥Space")
    }

    @Test("Command+A displays as ⌘A")
    func testCommandA() {
        let display = hotkeyDisplayString(keyCode: 0, modifiers: UInt32(cmdKey))
        #expect(display == "⌘A")
    }

    @Test("Control+Shift+F1 displays as ⌃⇧F1")
    func testControlShiftF1() {
        let mods = UInt32(controlKey) | UInt32(shiftKey)
        let display = hotkeyDisplayString(keyCode: 122, modifiers: mods)
        #expect(display == "⌃⇧F1")
    }

    @Test("All four modifiers display in correct order")
    func testAllModifiers() {
        let mods = UInt32(controlKey) | UInt32(optionKey) | UInt32(shiftKey) | UInt32(cmdKey)
        let display = hotkeyDisplayString(keyCode: 49, modifiers: mods)
        #expect(display == "⌃⌥⇧⌘Space")
    }

    @Test("No modifiers shows only key name")
    func testNoModifiers() {
        let display = hotkeyDisplayString(keyCode: 49, modifiers: 0)
        #expect(display == "Space")
    }

    @Test("Unknown key code shows fallback string")
    func testUnknownKeyCode() {
        let display = hotkeyDisplayString(keyCode: 999, modifiers: UInt32(optionKey))
        #expect(display == "⌥Key 999")
    }
}

// MARK: - Settings Persistence Tests

/// Tests that SettingsStore changes persist immediately (Requirement 10.5).
@MainActor
@Suite("SettingsView Settings Persistence")
struct SettingsViewPersistenceTests {

    private func makeStore(suiteName: String) -> SettingsStore {
        SettingsStore(
            defaults: UserDefaults(suiteName: suiteName)!
        )
    }

    @Test("Hotkey changes persist immediately across store instances")
    func testHotkeyPersistence() {
        let suite = "test.wispr.persist.hotkey.\(UUID().uuidString)"
        let store1 = makeStore(suiteName: suite)

        store1.hotkeyKeyCode = 0  // A
        store1.hotkeyModifiers = UInt32(cmdKey)

        let store2 = makeStore(suiteName: suite)
        #expect(store2.hotkeyKeyCode == 0)
        #expect(store2.hotkeyModifiers == UInt32(cmdKey))
    }

    @Test("Language mode changes persist immediately across store instances")
    func testLanguageModePersistence() {
        let suite = "test.wispr.persist.lang.\(UUID().uuidString)"
        let store1 = makeStore(suiteName: suite)

        store1.languageMode = .pinned(code: "ja")

        let store2 = makeStore(suiteName: suite)
        #expect(store2.languageMode == .pinned(code: "ja"))
    }

    @Test("Active model name changes persist immediately")
    func testModelNamePersistence() {
        let suite = "test.wispr.persist.model.\(UUID().uuidString)"
        let store1 = makeStore(suiteName: suite)

        store1.activeModelName = "large-v3"

        let store2 = makeStore(suiteName: suite)
        #expect(store2.activeModelName == "large-v3")
    }

    @Test("Launch at login changes persist immediately")
    func testLaunchAtLoginPersistence() {
        let suite = "test.wispr.persist.login.\(UUID().uuidString)"
        let store1 = makeStore(suiteName: suite)

        store1.launchAtLogin = true

        let store2 = makeStore(suiteName: suite)
        #expect(store2.launchAtLogin == true)
    }

    @Test("Audio device UID changes persist immediately")
    func testAudioDevicePersistence() {
        let suite = "test.wispr.persist.audio.\(UUID().uuidString)"
        let store1 = makeStore(suiteName: suite)

        store1.selectedAudioDeviceUID = "BuiltInMicrophoneDevice"

        let store2 = makeStore(suiteName: suite)
        #expect(store2.selectedAudioDeviceUID == "BuiltInMicrophoneDevice")
    }
}

// MARK: - Supported Languages List Tests

/// Tests the SupportedLanguage list completeness and structure.
/// Validates: Requirement 16.3
@MainActor
@Suite("SettingsView Supported Languages")
struct SettingsViewSupportedLanguagesTests {

    @Test("Supported languages list is not empty")
    func testLanguagesNotEmpty() {
        #expect(!SupportedLanguage.all.isEmpty)
    }

    @Test("Supported languages list contains major languages")
    func testMajorLanguagesPresent() {
        let codes = Set(SupportedLanguage.all.map(\.id))
        let majorLanguages = ["en", "zh", "es", "fr", "de", "ja", "ko", "pt", "ru", "ar", "hi", "it"]
        for code in majorLanguages {
            #expect(codes.contains(code), "Missing major language: \(code)")
        }
    }

    @Test("All language IDs are unique")
    func testUniqueLanguageIDs() {
        let ids = SupportedLanguage.all.map(\.id)
        let uniqueIDs = Set(ids)
        #expect(ids.count == uniqueIDs.count, "Duplicate language IDs found")
    }

    @Test("All language names are non-empty")
    func testNonEmptyNames() {
        for lang in SupportedLanguage.all {
            #expect(!lang.name.isEmpty, "Language \(lang.id) has empty name")
        }
    }

    @Test("English is the first language in the list")
    func testEnglishFirst() {
        #expect(SupportedLanguage.all.first?.id == "en")
        #expect(SupportedLanguage.all.first?.name == "English")
    }
}
