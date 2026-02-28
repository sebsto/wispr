//
//  MultiLanguageTests.swift
//  wisprTests
//
//  Unit tests for multi-language transcription support.
//  Requirements: 16.2, 16.4, 16.5
//

import Testing
import Foundation
@testable import wispr

// MARK: - TranscriptionLanguage Enum Tests

@MainActor
@Suite("TranscriptionLanguage Enum")
struct TranscriptionLanguageEnumTests {

    // MARK: - isAutoDetect

    /// Requirement 16.2: Auto-detect mode identification.
    @Test("isAutoDetect returns true for autoDetect case")
    func testIsAutoDetectTrue() {
        let lang = TranscriptionLanguage.autoDetect
        let result = lang.isAutoDetect
        #expect(result == true)
    }

    @Test("isAutoDetect returns false for specific case")
    func testIsAutoDetectFalseSpecific() {
        let lang = TranscriptionLanguage.specific(code: "en")
        let result = lang.isAutoDetect
        #expect(result == false)
    }

    @Test("isAutoDetect returns false for pinned case")
    func testIsAutoDetectFalsePinned() {
        let lang = TranscriptionLanguage.pinned(code: "ja")
        let result = lang.isAutoDetect
        #expect(result == false)
    }

    // MARK: - isPinned

    /// Requirement 16.5: Pinned language identification.
    @Test("isPinned returns true for pinned case")
    func testIsPinnedTrue() {
        let lang = TranscriptionLanguage.pinned(code: "de")
        let result = lang.isPinned
        #expect(result == true)
    }

    @Test("isPinned returns false for autoDetect case")
    func testIsPinnedFalseAutoDetect() {
        let lang = TranscriptionLanguage.autoDetect
        let result = lang.isPinned
        #expect(result == false)
    }

    @Test("isPinned returns false for specific case")
    func testIsPinnedFalseSpecific() {
        let lang = TranscriptionLanguage.specific(code: "en")
        let result = lang.isPinned
        #expect(result == false)
    }

    // MARK: - languageCode

    /// Requirement 16.4: Language code extraction for specific/pinned modes.
    @Test("languageCode returns nil for autoDetect")
    func testLanguageCodeAutoDetect() {
        let lang = TranscriptionLanguage.autoDetect
        let code = lang.languageCode
        #expect(code == nil)
    }

    @Test("languageCode returns code for specific")
    func testLanguageCodeSpecific() {
        let lang = TranscriptionLanguage.specific(code: "es")
        let code = lang.languageCode
        #expect(code == "es")
    }

    @Test("languageCode returns code for pinned")
    func testLanguageCodePinned() {
        let lang = TranscriptionLanguage.pinned(code: "fr")
        let code = lang.languageCode
        #expect(code == "fr")
    }

    // MARK: - Equatable

    @Test("autoDetect equals autoDetect")
    func testAutoDetectEquality() {
        #expect(TranscriptionLanguage.autoDetect == TranscriptionLanguage.autoDetect)
    }

    @Test("specific with same code are equal")
    func testSpecificEquality() {
        #expect(TranscriptionLanguage.specific(code: "en") == TranscriptionLanguage.specific(code: "en"))
    }

    @Test("specific with different codes are not equal")
    func testSpecificInequality() {
        #expect(TranscriptionLanguage.specific(code: "en") != TranscriptionLanguage.specific(code: "fr"))
    }

    @Test("pinned with same code are equal")
    func testPinnedEquality() {
        #expect(TranscriptionLanguage.pinned(code: "ja") == TranscriptionLanguage.pinned(code: "ja"))
    }

    @Test("specific and pinned with same code are not equal")
    func testSpecificVsPinnedInequality() {
        #expect(TranscriptionLanguage.specific(code: "en") != TranscriptionLanguage.pinned(code: "en"))
    }

    @Test("autoDetect and specific are not equal")
    func testAutoDetectVsSpecificInequality() {
        #expect(TranscriptionLanguage.autoDetect != TranscriptionLanguage.specific(code: "en"))
    }

    // MARK: - Codable Round-Trip

    @Test("autoDetect survives JSON encode/decode round-trip")
    func testAutoDetectCodable() throws {
        let original = TranscriptionLanguage.autoDetect
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionLanguage.self, from: data)
        #expect(decoded == original)
    }

    @Test("specific survives JSON encode/decode round-trip")
    func testSpecificCodable() throws {
        let original = TranscriptionLanguage.specific(code: "zh")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionLanguage.self, from: data)
        #expect(decoded == original)
    }

    @Test("pinned survives JSON encode/decode round-trip")
    func testPinnedCodable() throws {
        let original = TranscriptionLanguage.pinned(code: "ko")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TranscriptionLanguage.self, from: data)
        #expect(decoded == original)
    }
}

// MARK: - Language Mode Persistence Tests

@MainActor
@Suite("Language Mode Persistence")
struct LanguageModePersistenceTests {

    /// Helper to create an isolated UserDefaults for each test.
    func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "test.wispr.multilang.\(UUID().uuidString)")!
    }

    // MARK: - Requirement 16.5: Persist selected language across restarts

    @Test("Specific language persists across SettingsStore instances")
    func testSpecificLanguagePersistence() {
        let defaults = makeDefaults()
        let store1 = SettingsStore(defaults: defaults)
        store1.languageMode = .specific(code: "pt")

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.languageMode == .specific(code: "pt"))
    }

    @Test("Pinned language persists across SettingsStore instances")
    func testPinnedLanguagePersistence() {
        let defaults = makeDefaults()
        let store1 = SettingsStore(defaults: defaults)
        store1.languageMode = .pinned(code: "it")

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.languageMode == .pinned(code: "it"))
    }

    @Test("Auto-detect mode persists across SettingsStore instances")
    func testAutoDetectPersistence() {
        let defaults = makeDefaults()
        let store1 = SettingsStore(defaults: defaults)
        // First set to something else, then back to autoDetect
        store1.languageMode = .specific(code: "en")
        store1.languageMode = .autoDetect

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.languageMode == .autoDetect)
    }

    // MARK: - Language Mode Transitions

    /// Requirement 16.5: Language selection persists for subsequent sessions.
    /// Requirement 16.4: User selects specific language.
    @Test("Transition: autoDetect → specific → pinned → autoDetect")
    func testLanguageModeTransitionCycle() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        // Start at autoDetect (default)
        var isAuto = store.languageMode.isAutoDetect
        #expect(isAuto)

        // Transition to specific
        store.languageMode = .specific(code: "de")
        #expect(store.languageMode == .specific(code: "de"))
        var code = store.languageMode.languageCode
        #expect(code == "de")
        isAuto = store.languageMode.isAutoDetect
        #expect(isAuto == false)
        var pinned = store.languageMode.isPinned
        #expect(pinned == false)

        // Transition to pinned
        store.languageMode = .pinned(code: "de")
        #expect(store.languageMode == .pinned(code: "de"))
        pinned = store.languageMode.isPinned
        #expect(pinned == true)
        code = store.languageMode.languageCode
        #expect(code == "de")

        // Transition back to autoDetect
        store.languageMode = .autoDetect
        isAuto = store.languageMode.isAutoDetect
        #expect(isAuto == true)
        code = store.languageMode.languageCode
        #expect(code == nil)

        // Verify final state persists
        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.languageMode == .autoDetect)
    }

    @Test("Switching from pinned to autoDetect clears language code")
    func testPinnedToAutoDetectClearsCode() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        store.languageMode = .pinned(code: "ja")
        var code = store.languageMode.languageCode
        #expect(code == "ja")

        store.languageMode = .autoDetect
        code = store.languageMode.languageCode
        #expect(code == nil)
        let isAuto = store.languageMode.isAutoDetect
        #expect(isAuto == true)
    }

    @Test("Changing specific language code updates persisted value")
    func testChangeSpecificLanguageCode() {
        let defaults = makeDefaults()
        let store = SettingsStore(defaults: defaults)

        store.languageMode = .specific(code: "en")
        store.languageMode = .specific(code: "fr")

        let store2 = SettingsStore(defaults: defaults)
        #expect(store2.languageMode == .specific(code: "fr"))
    }
}

// MARK: - StateManager Language Sync Tests

@MainActor
@Suite("StateManager Language Sync")
struct StateManagerLanguageSyncTests {

    /// Helper to create a StateManager with an isolated SettingsStore.
    func makeStateManager(languageMode: TranscriptionLanguage = .autoDetect) -> (StateManager, SettingsStore) {
        let defaults = UserDefaults(suiteName: "test.wispr.sm.lang.\(UUID().uuidString)")!
        let settingsStore = SettingsStore(defaults: defaults)
        settingsStore.languageMode = languageMode

        let sm = StateManager(
            audioEngine: AudioEngine(),
            whisperService: WhisperService(),
            textInsertionService: TextInsertionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settingsStore
        )
        return (sm, settingsStore)
    }

    /// Requirement 16.2: StateManager initializes with autoDetect from SettingsStore.
    @Test("StateManager initializes currentLanguage from SettingsStore autoDetect")
    func testInitAutoDetect() {
        let (sm, _) = makeStateManager(languageMode: .autoDetect)
        #expect(sm.currentLanguage == .autoDetect)
    }

    /// Requirement 16.4: StateManager initializes with specific language from SettingsStore.
    @Test("StateManager initializes currentLanguage from SettingsStore specific")
    func testInitSpecific() {
        let (sm, _) = makeStateManager(languageMode: .specific(code: "es"))
        #expect(sm.currentLanguage == .specific(code: "es"))
    }

    /// Requirement 16.5: StateManager initializes with pinned language from SettingsStore.
    @Test("StateManager initializes currentLanguage from SettingsStore pinned")
    func testInitPinned() {
        let (sm, _) = makeStateManager(languageMode: .pinned(code: "zh"))
        #expect(sm.currentLanguage == .pinned(code: "zh"))
    }
}

// MARK: - WhisperService Language Parameter Tests

@Suite("WhisperService Language Parameters")
struct WhisperServiceLanguageParameterTests {

    /// Requirement 16.2: Auto-detect passes nil language to WhisperKit.
    /// Since no model is loaded, we verify the error is modelNotDownloaded
    /// (meaning the language parameter was accepted and processing reached the model check).
    @Test("transcribe with autoDetect reaches model check")
    func testAutoDetectReachesModelCheck() async {
        let service = WhisperService()
        let samples: [Float] = Array(repeating: 0.0, count: 16000)

        do {
            _ = try await service.transcribe(samples, language: .autoDetect)
            Issue.record("Expected modelNotDownloaded error")
        } catch let error as WisprError {
            #expect(error == .modelNotDownloaded)
        } catch {
            Issue.record("Expected WisprError, got \(error)")
        }
    }

    /// Requirement 16.4: Specific language passes code to WhisperKit.
    @Test("transcribe with specific language reaches model check")
    func testSpecificLanguageReachesModelCheck() async {
        let service = WhisperService()
        let samples: [Float] = Array(repeating: 0.0, count: 16000)

        do {
            _ = try await service.transcribe(samples, language: .specific(code: "en"))
            Issue.record("Expected modelNotDownloaded error")
        } catch let error as WisprError {
            #expect(error == .modelNotDownloaded)
        } catch {
            Issue.record("Expected WisprError, got \(error)")
        }
    }

    /// Requirement 16.4: Pinned language passes code to WhisperKit.
    @Test("transcribe with pinned language reaches model check")
    func testPinnedLanguageReachesModelCheck() async {
        let service = WhisperService()
        let samples: [Float] = Array(repeating: 0.0, count: 16000)

        do {
            _ = try await service.transcribe(samples, language: .pinned(code: "fr"))
            Issue.record("Expected modelNotDownloaded error")
        } catch let error as WisprError {
            #expect(error == .modelNotDownloaded)
        } catch {
            Issue.record("Expected WisprError, got \(error)")
        }
    }

    /// Verify that all three language modes are accepted by the transcribe API
    /// without causing unexpected errors (only modelNotDownloaded is expected).
    @Test("All language modes produce consistent modelNotDownloaded error")
    func testAllModesConsistentError() async {
        let service = WhisperService()
        let samples: [Float] = Array(repeating: 0.1, count: 8000)

        let modes: [TranscriptionLanguage] = [
            .autoDetect,
            .specific(code: "en"),
            .specific(code: "ja"),
            .pinned(code: "de"),
            .pinned(code: "zh"),
        ]

        for mode in modes {
            do {
                _ = try await service.transcribe(samples, language: mode)
                Issue.record("Expected error for mode \(mode)")
            } catch let error as WisprError {
                #expect(error == .modelNotDownloaded, "Expected modelNotDownloaded for \(mode), got \(error)")
            } catch {
                Issue.record("Expected WisprError for \(mode), got \(error)")
            }
        }
    }
}
