//
//  PreviewHelpers.swift
//  wispr
//
//  Lightweight mock/fake objects for SwiftUI canvas previews.
//  These never touch system services (Carbon hotkeys, AX permissions,
//  AVAudioEngine, etc.) so previews render without crashing.
//

import SwiftUI

#if DEBUG

// MARK: - Preview-Safe StateManager

/// A preview-safe StateManager that skips hotkey wiring and language sync.
///
/// We achieve this by subclassing nothing — StateManager is a final class,
/// so instead we create a standalone @Observable class with the same
/// published properties that RecordingOverlayView and OnboardingFlow read.
///
/// Since StateManager is `final` and views use `@Environment(StateManager.self)`,
/// we need to provide a real StateManager instance. The trick is to give it
/// dependencies whose inits are harmless in preview context.
///
/// AudioEngine and WhisperService are actors — their inits do nothing dangerous.
/// HotkeyMonitor's init is fine; it's `register()` that touches Carbon.
/// TextInsertionService's init is fine; it's `insertText()` that uses AX APIs.
/// PermissionManager's init calls checkPermissions() which calls AXIsProcessTrusted()
/// and AVAudioApplication — these return false in preview but don't crash.
/// SettingsStore's init with ephemeral UserDefaults avoids polluting real prefs.
///
/// The only dangerous part is StateManager.init calling setupHotkeyCallbacks()
/// (which just sets closures — safe) and startLanguageSync() (which starts a
/// Task that observes settingsStore — safe in preview).
///
/// So actually, the real StateManager with default-constructed dependencies
/// should work IF we use ephemeral UserDefaults for SettingsStore.

@MainActor
enum PreviewMocks {

    // MARK: - Ephemeral SettingsStore

    /// SettingsStore backed by an ephemeral UserDefaults suite.
    /// Doesn't read/write the app's real preferences.
    static func makeSettingsStore() -> SettingsStore {
        let defaults = UserDefaults(suiteName: "com.wispr.preview.\(UUID().uuidString)")!
        return SettingsStore(defaults: defaults)
    }

    // MARK: - Safe Service Instances

    /// These service inits are lightweight — no system resource allocation.
    static func makeAudioEngine() -> AudioEngine { AudioEngine() }
    static func makeWhisperService() -> WhisperService { WhisperService() }
    static func makeHotkeyMonitor() -> HotkeyMonitor { HotkeyMonitor() }
    static func makeTextInsertionService() -> TextInsertionService { TextInsertionService() }
    static func makePermissionManager() -> PermissionManager { PermissionManager() }
    static func makeTheme() -> UIThemeEngine { UIThemeEngine() }

    // MARK: - Full StateManager (for views that need it)

    /// Creates a real StateManager with safe, ephemeral dependencies.
    /// setupHotkeyCallbacks() just sets closures (no Carbon registration).
    /// startLanguageSync() starts a benign observation Task.
    static func makeStateManager(settingsStore: SettingsStore? = nil) -> StateManager {
        let store = settingsStore ?? makeSettingsStore()
        return StateManager(
            audioEngine: makeAudioEngine(),
            whisperService: makeWhisperService(),
            textInsertionService: makeTextInsertionService(),
            hotkeyMonitor: makeHotkeyMonitor(),
            permissionManager: makePermissionManager(),
            settingsStore: store
        )
    }

    // MARK: - Sample Model Data

    static let sampleModels: [WhisperModelInfo] = [
        WhisperModelInfo(id: "tiny", displayName: "Tiny", sizeDescription: "~75 MB",
                         qualityDescription: "Fastest, lower accuracy", status: .active),
        WhisperModelInfo(id: "base", displayName: "Base", sizeDescription: "~140 MB",
                         qualityDescription: "Fast, moderate accuracy", status: .downloaded),
        WhisperModelInfo(id: "small", displayName: "Small", sizeDescription: "~460 MB",
                         qualityDescription: "Balanced speed and accuracy", status: .notDownloaded),
        WhisperModelInfo(id: "medium", displayName: "Medium", sizeDescription: "~1.5 GB",
                         qualityDescription: "Slower, high accuracy", status: .downloading(progress: 0.45)),
        WhisperModelInfo(id: "large-v3", displayName: "Large v3", sizeDescription: "~3 GB",
                         qualityDescription: "Slowest, highest accuracy", status: .notDownloaded),
    ]
}

#endif
