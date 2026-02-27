//
//  SettingsStore.swift
//  wispr
//
//  Settings persistence using UserDefaults
//

import Foundation
import Observation

@MainActor
@Observable
final class SettingsStore {
    // MARK: - Hotkey Settings
    var hotkeyKeyCode: UInt32 {
        didSet { save() }
    }
    
    var hotkeyModifiers: UInt32 {
        didSet { save() }
    }
    
    // MARK: - Audio Settings
    var selectedAudioDeviceUID: String? {
        didSet { save() }
    }
    
    // MARK: - Model Settings
    var activeModelName: String {
        didSet { save() }
    }
    
    // MARK: - Language Settings
    var languageMode: TranscriptionLanguage {
        didSet { save() }
    }
    
    // MARK: - General Settings
    var launchAtLogin: Bool {
        didSet { save() }
    }
    
    var onboardingCompleted: Bool {
        didSet { save() }
    }
    
    var onboardingLastStep: Int {
        didSet { save() }
    }
    
    // MARK: - UserDefaults Keys
    private enum Keys {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let selectedAudioDeviceUID = "selectedAudioDeviceUID"
        static let activeModelName = "activeModelName"
        static let languageMode = "languageMode"
        static let launchAtLogin = "launchAtLogin"
        static let onboardingCompleted = "onboardingCompleted"
        static let onboardingLastStep = "onboardingLastStep"
    }
    
    // MARK: - Dependencies
    private let defaults: UserDefaults
    private var isLoading = false
    
    // MARK: - Initialization
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        
        // Initialize with defaults
        self.hotkeyKeyCode = 49  // Space
        self.hotkeyModifiers = 2048  // Option
        self.selectedAudioDeviceUID = nil
        self.activeModelName = "openai_whisper-tiny"
        self.languageMode = .autoDetect
        self.launchAtLogin = false
        self.onboardingCompleted = false
        self.onboardingLastStep = 0
        
        // Load persisted values
        load()
    }
    
    // MARK: - Persistence
    func save() {
        // Don't save while loading to avoid overwriting persisted values
        guard !isLoading else { return }
        
        defaults.set(Int(hotkeyKeyCode), forKey: Keys.hotkeyKeyCode)
        defaults.set(Int(hotkeyModifiers), forKey: Keys.hotkeyModifiers)
        defaults.set(selectedAudioDeviceUID, forKey: Keys.selectedAudioDeviceUID)
        defaults.set(activeModelName, forKey: Keys.activeModelName)
        defaults.set(launchAtLogin, forKey: Keys.launchAtLogin)
        defaults.set(onboardingCompleted, forKey: Keys.onboardingCompleted)
        defaults.set(onboardingLastStep, forKey: Keys.onboardingLastStep)
        
        // Encode languageMode
        if let encoded = try? JSONEncoder().encode(languageMode) {
            defaults.set(encoded, forKey: Keys.languageMode)
        }
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
        self.launchAtLogin = defaults.bool(forKey: Keys.launchAtLogin)
        self.onboardingCompleted = defaults.bool(forKey: Keys.onboardingCompleted)
        
        self.onboardingLastStep = defaults.integer(forKey: Keys.onboardingLastStep)
    }
}
