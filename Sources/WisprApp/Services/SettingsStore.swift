//
//  SettingsStore.swift
//  wispr
//
//  Settings persistence using UserDefaults
//

import WisprCore
import Foundation
import Observation
import ServiceManagement
import os

@MainActor
@Observable
final class SettingsStore {
    // MARK: - Hotkey Settings
    var hotkeyKeyCode: UInt32 {
        didSet { guard !isLoading else { return }; defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode) }
    }

    var hotkeyModifiers: UInt32 {
        didSet { guard !isLoading else { return }; defaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers) }
    }

    // MARK: - Audio Settings
    var selectedAudioDeviceUID: String? {
        didSet { guard !isLoading else { return }; defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID) }
    }

    // MARK: - Model Settings
    var activeModelName: String {
        didSet { guard !isLoading else { return }; defaults.set(activeModelName, forKey: Keys.activeModelName) }
    }

    // MARK: - Language Settings
    var languageMode: TranscriptionLanguage {
        didSet {
            guard !isLoading else { return }
            if let encoded = try? JSONEncoder().encode(languageMode) {
                defaults.set(encoded, forKey: Keys.languageMode)
            }
        }
    }

    // MARK: - General Settings
    var showRecordingOverlay: Bool {
        didSet { guard !isLoading else { return }; defaults.set(showRecordingOverlay, forKey: Keys.showRecordingOverlay) }
    }

    var launchAtLogin: Bool {
        didSet {
            guard !isLoading else { return }
            updateLaunchAtLogin(launchAtLogin)
        }
    }

    var onboardingCompleted: Bool {
        didSet { guard !isLoading else { return }; defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted) }
    }

    var onboardingLastStep: Int {
        didSet { guard !isLoading else { return }; defaults.set(onboardingLastStep, forKey: Keys.onboardingLastStep) }
    }
    
    // MARK: - Dictation Mode

    /// When true, hotkey toggles recording on/off (press once to start, press again to stop).
    /// When false, uses push-to-talk (hold to record, release to stop).
    var handsFreeMode: Bool {
        didSet { guard !isLoading else { return }; defaults.set(handsFreeMode, forKey: Keys.handsFreeMode) }
    }

    /// When true, plays short audio cues on recording start/stop.
    var soundFeedbackEnabled: Bool {
        didSet { guard !isLoading else { return }; defaults.set(soundFeedbackEnabled, forKey: Keys.soundFeedbackEnabled) }
    }

    // MARK: - Auto-Suffix Settings

    /// When true, appends `autoSuffixText` to transcribed text before insertion.
    var autoSuffixEnabled: Bool {
        didSet { guard !isLoading else { return }; defaults.set(autoSuffixEnabled, forKey: Keys.autoSuffixEnabled) }
    }

    /// The suffix string appended to transcribed text when `autoSuffixEnabled` is true.
    var autoSuffixText: String {
        didSet { guard !isLoading else { return }; defaults.set(autoSuffixText, forKey: Keys.autoSuffixText) }
    }

    // MARK: - Filler Word Removal Settings

    /// When true, removes common filler words (um, uh, ah, etc.) from transcriptions before insertion.
    var removeFillerWords: Bool {
        didSet { guard !isLoading else { return }; defaults.set(removeFillerWords, forKey: Keys.removeFillerWords) }
    }

    // MARK: - Auto-Send Enter Settings

    /// When true, simulates an Enter/Return keystroke after text insertion.
    var autoSendEnterEnabled: Bool {
        didSet { guard !isLoading else { return }; defaults.set(autoSendEnterEnabled, forKey: Keys.autoSendEnterEnabled) }
    }

    // MARK: - AI Text Correction Settings

    /// When true, applies on-device AI text correction after filler word removal.
    var aiTextCorrectionEnabled: Bool {
        didSet { guard !isLoading else { return }; defaults.set(aiTextCorrectionEnabled, forKey: Keys.aiTextCorrectionEnabled) }
    }

    /// The correction style used by AI text correction.
    var aiTextCorrectionStyle: CorrectionStyle {
        didSet {
            guard !isLoading else { return }
            if let encoded = try? JSONEncoder().encode(aiTextCorrectionStyle) {
                defaults.set(encoded, forKey: Keys.aiTextCorrectionStyle)
            }
        }
    }

    // MARK: - UserDefaults Keys
    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let activeModelName = "activeModelName"
        static let languageMode = "languageMode"
        static let showRecordingOverlay = "showRecordingOverlay"
        static let launchAtLogin = "launchAtLogin"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingLastStep = "onboardingLastStep"
        static let handsFreeMode = "handsFreeMode"
        static let soundFeedbackEnabled = "soundFeedbackEnabled"
        static let autoSuffixEnabled = "autoSuffixEnabled"
        static let autoSuffixText = "autoSuffixText"
        static let removeFillerWords = "removeFillerWords"
        static let autoSendEnterEnabled = "autoSendEnterEnabled"
        static let aiTextCorrectionEnabled = "aiTextCorrectionEnabled"
        static let aiTextCorrectionStyle = "aiTextCorrectionStyle"
    }
    
    // MARK: - Default Values

    /// Single source of truth for all setting defaults.
    /// Referenced by `init`, `restoreDefaults()`, and tests.
    enum Defaults {
        static let hotkeyKeyCode: UInt32 = 49          // Space
        static let hotkeyModifiers: UInt32 = 2048      // Option
        static let selectedAudioDeviceUID: String? = nil
        static let activeModelName: String = ModelInfo.KnownID.tiny
        static let languageMode: TranscriptionLanguage = .autoDetect
        static let showRecordingOverlay: Bool = true
        static let launchAtLogin: Bool = false
        static let onboardingCompleted: Bool = false
        static let onboardingLastStep: Int = 0
        static let handsFreeMode: Bool = false
        static let soundFeedbackEnabled: Bool = false
        static let autoSuffixEnabled: Bool = false
        static let autoSuffixText: String = " "
        static let removeFillerWords: Bool = false
        static let autoSendEnterEnabled: Bool = false
        static let aiTextCorrectionEnabled: Bool = false
        static let aiTextCorrectionStyle: CorrectionStyle = .minimal
    }

    // MARK: - Dependencies
    private let defaults: UserDefaults
    private var isLoading = false
    
    // MARK: - Initialization
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        // Initialize with defaults
        self.hotkeyKeyCode = Defaults.hotkeyKeyCode
        self.hotkeyModifiers = Defaults.hotkeyModifiers
        self.selectedAudioDeviceUID = Defaults.selectedAudioDeviceUID
        self.activeModelName = Defaults.activeModelName
        self.languageMode = Defaults.languageMode
        self.showRecordingOverlay = Defaults.showRecordingOverlay
        self.launchAtLogin = Defaults.launchAtLogin
        self.onboardingCompleted = Defaults.onboardingCompleted
        self.onboardingLastStep = Defaults.onboardingLastStep
        self.handsFreeMode = Defaults.handsFreeMode
        self.soundFeedbackEnabled = Defaults.soundFeedbackEnabled
        self.autoSuffixEnabled = Defaults.autoSuffixEnabled
        self.autoSuffixText = Defaults.autoSuffixText
        self.removeFillerWords = Defaults.removeFillerWords
        self.autoSendEnterEnabled = Defaults.autoSendEnterEnabled
        self.aiTextCorrectionEnabled = Defaults.aiTextCorrectionEnabled
        self.aiTextCorrectionStyle = Defaults.aiTextCorrectionStyle

        // Load persisted values
        load()
    }

    // MARK: - Restore Defaults

    /// Resets all user-facing settings to their default values.
    /// This is the single source of truth — call this from SettingsView
    /// instead of duplicating default values.
    func restoreDefaults() {
        hotkeyKeyCode = Defaults.hotkeyKeyCode
        hotkeyModifiers = Defaults.hotkeyModifiers
        selectedAudioDeviceUID = Defaults.selectedAudioDeviceUID
        activeModelName = Defaults.activeModelName
        languageMode = Defaults.languageMode
        showRecordingOverlay = Defaults.showRecordingOverlay
        launchAtLogin = Defaults.launchAtLogin
        handsFreeMode = Defaults.handsFreeMode
        soundFeedbackEnabled = Defaults.soundFeedbackEnabled
        autoSuffixEnabled = Defaults.autoSuffixEnabled
        autoSuffixText = Defaults.autoSuffixText
        removeFillerWords = Defaults.removeFillerWords
        autoSendEnterEnabled = Defaults.autoSendEnterEnabled
        aiTextCorrectionEnabled = Defaults.aiTextCorrectionEnabled
        aiTextCorrectionStyle = Defaults.aiTextCorrectionStyle
    }
    
    // MARK: - Persistence

    /// Persists all current values to UserDefaults without forcing a disk flush.
    /// Safe to call frequently — each `defaults.set` is cheap (in-memory update
    /// that the system coalesces and writes to disk on its own schedule).
    func save() {
        guard !isLoading else { return }

        defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode)
        defaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers)
        defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID)
        defaults.set(activeModelName, forKey: Keys.activeModelName)
        defaults.set(showRecordingOverlay, forKey: Keys.showRecordingOverlay)
        defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
        defaults.set(onboardingLastStep, forKey: Keys.onboardingLastStep)
        defaults.set(handsFreeMode, forKey: Keys.handsFreeMode)
        defaults.set(soundFeedbackEnabled, forKey: Keys.soundFeedbackEnabled)
        defaults.set(autoSuffixEnabled, forKey: Keys.autoSuffixEnabled)
        defaults.set(autoSuffixText, forKey: Keys.autoSuffixText)
        defaults.set(removeFillerWords, forKey: Keys.removeFillerWords)
        defaults.set(autoSendEnterEnabled, forKey: Keys.autoSendEnterEnabled)
        defaults.set(aiTextCorrectionEnabled, forKey: Keys.aiTextCorrectionEnabled)

        if let encoded = try? JSONEncoder().encode(languageMode) {
            defaults.set(encoded, forKey: Keys.languageMode)
        }

        if let encoded = try? JSONEncoder().encode(aiTextCorrectionStyle) {
            defaults.set(encoded, forKey: Keys.aiTextCorrectionStyle)
        }
    }

    /// Persists all values and forces cfprefsd to flush to disk immediately.
    /// Only call this at critical moments (app termination, onboarding completion)
    /// where an abrupt process exit could lose in-memory changes.
    func flush() {
        save()
        defaults.synchronize()
    }
    
    func load() {
        isLoading = true
        defer { isLoading = false }
        
        // Load hotkey settings
        let storedKeyCode = defaults.integer(forKey: Keys.hotkeyKeyCode)
        if storedKeyCode != 0 || defaults.object(forKey: Keys.hotkeyKeyCode) != nil {
            self.hotkeyKeyCode = UInt32(storedKeyCode)
        }
        
        let storedModifiers = defaults.integer(forKey: Keys.hotkeyModifiers)
        if storedModifiers != 0 || defaults.object(forKey: Keys.hotkeyModifiers) != nil {
            self.hotkeyModifiers = UInt32(storedModifiers)
        }
        
        // Load audio settings
        self.selectedAudioDeviceUID = defaults.string(forKey: Keys.selectedAudioDeviceUID)
        
        // Load model settings
        if let modelName = defaults.string(forKey: Keys.activeModelName) {
            self.activeModelName = modelName
        }
        
        // Load language mode
        if let data = defaults.data(forKey: Keys.languageMode),
           let decoded = try? JSONDecoder().decode(TranscriptionLanguage.self, from: data) {
            self.languageMode = decoded
        }
        
        // Load general settings
        if defaults.object(forKey: Keys.showRecordingOverlay) != nil {
            self.showRecordingOverlay = defaults.bool(forKey: Keys.showRecordingOverlay)
        }
        self.launchAtLogin = SMAppService.mainApp.status == .enabled
        self.onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        
        self.onboardingLastStep = defaults.integer(forKey: Keys.onboardingLastStep)
        
        if defaults.object(forKey: Keys.handsFreeMode) != nil {
            self.handsFreeMode = defaults.bool(forKey: Keys.handsFreeMode)
        }

        if defaults.object(forKey: Keys.soundFeedbackEnabled) != nil {
            self.soundFeedbackEnabled = defaults.bool(forKey: Keys.soundFeedbackEnabled)
        }

        // Load auto-suffix settings
        if defaults.object(forKey: Keys.autoSuffixEnabled) != nil {
            self.autoSuffixEnabled = defaults.bool(forKey: Keys.autoSuffixEnabled)
        }

        if let suffixText = defaults.string(forKey: Keys.autoSuffixText) {
            self.autoSuffixText = suffixText
        }

        // Load filler word removal setting
        if defaults.object(forKey: Keys.removeFillerWords) != nil {
            self.removeFillerWords = defaults.bool(forKey: Keys.removeFillerWords)
        }

        // Load auto-send Enter settings
        if defaults.object(forKey: Keys.autoSendEnterEnabled) != nil {
            self.autoSendEnterEnabled = defaults.bool(forKey: Keys.autoSendEnterEnabled)
        }

        // Load AI text correction settings
        if defaults.object(forKey: Keys.aiTextCorrectionEnabled) != nil {
            self.aiTextCorrectionEnabled = defaults.bool(forKey: Keys.aiTextCorrectionEnabled)
        }

        if let data = defaults.data(forKey: Keys.aiTextCorrectionStyle),
           let decoded = try? JSONDecoder().decode(CorrectionStyle.self, from: data) {
            self.aiTextCorrectionStyle = decoded
        }
    }
    
    // MARK: - Launch at Login
    
    /// Registers or unregisters the app as a login item using ServiceManagement.
    /// After the operation, reads back the actual system state so the toggle
    /// always reflects reality.
    /// Requirements: 10.3, 10.4
    func updateLaunchAtLogin(_ enabled: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                // unregister() throws if the app was never registered — that's
                // not a real failure, the desired state (not registered) is already true.
                if service.status != .notRegistered {
                    try service.unregister()
                }
            }
        } catch {
            Log.app.error("Failed to \(enabled ? "register" : "unregister") login item: \(error)")
        }
        
        // Always sync back to the actual system state.
        // The source of truth for launch-at-login is ServiceManagement, not UserDefaults,
        // so no explicit defaults.set is needed — load() reads from SMAppService.mainApp.status.
        let actualState = service.status == .enabled
        if launchAtLogin != actualState {
            isLoading = true
            launchAtLogin = actualState
            isLoading = false
        }
    }
}
