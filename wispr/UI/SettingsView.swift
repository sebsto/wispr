//
//  SettingsView.swift
//  wispr
//
//  SwiftUI Form-based settings view with sections for Hotkey Configuration,
//  Audio Device, Whisper Model, Language, and General.
//  Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 14.3, 14.5, 14.12,
//                16.3, 16.4, 16.5, 16.6, 16.9, 16.10, 16.11
//

import SwiftUI
import Carbon

// MARK: - Supported Languages

/// Languages supported by Whisper models for transcription.
/// Requirement 16.3, 16.4: Language selection for transcription.
struct SupportedLanguage: Identifiable, Sendable {
    let id: String   // ISO 639-1 code
    let name: String // Display name

    static let all: [SupportedLanguage] = [
        SupportedLanguage(id: "en", name: "English"),
        SupportedLanguage(id: "zh", name: "Chinese"),
        SupportedLanguage(id: "de", name: "German"),
        SupportedLanguage(id: "es", name: "Spanish"),
        SupportedLanguage(id: "ru", name: "Russian"),
        SupportedLanguage(id: "ko", name: "Korean"),
        SupportedLanguage(id: "fr", name: "French"),
        SupportedLanguage(id: "ja", name: "Japanese"),
        SupportedLanguage(id: "pt", name: "Portuguese"),
        SupportedLanguage(id: "tr", name: "Turkish"),
        SupportedLanguage(id: "pl", name: "Polish"),
        SupportedLanguage(id: "ca", name: "Catalan"),
        SupportedLanguage(id: "nl", name: "Dutch"),
        SupportedLanguage(id: "ar", name: "Arabic"),
        SupportedLanguage(id: "sv", name: "Swedish"),
        SupportedLanguage(id: "it", name: "Italian"),
        SupportedLanguage(id: "id", name: "Indonesian"),
        SupportedLanguage(id: "hi", name: "Hindi"),
        SupportedLanguage(id: "fi", name: "Finnish"),
        SupportedLanguage(id: "vi", name: "Vietnamese"),
        SupportedLanguage(id: "he", name: "Hebrew"),
        SupportedLanguage(id: "uk", name: "Ukrainian"),
        SupportedLanguage(id: "el", name: "Greek"),
        SupportedLanguage(id: "ms", name: "Malay"),
        SupportedLanguage(id: "cs", name: "Czech"),
        SupportedLanguage(id: "ro", name: "Romanian"),
        SupportedLanguage(id: "da", name: "Danish"),
        SupportedLanguage(id: "hu", name: "Hungarian"),
        SupportedLanguage(id: "ta", name: "Tamil"),
        SupportedLanguage(id: "no", name: "Norwegian"),
        SupportedLanguage(id: "th", name: "Thai"),
        SupportedLanguage(id: "ur", name: "Urdu"),
        SupportedLanguage(id: "hr", name: "Croatian"),
        SupportedLanguage(id: "bg", name: "Bulgarian"),
        SupportedLanguage(id: "lt", name: "Lithuanian"),
        SupportedLanguage(id: "la", name: "Latin"),
        SupportedLanguage(id: "mi", name: "Maori"),
        SupportedLanguage(id: "ml", name: "Malayalam"),
        SupportedLanguage(id: "cy", name: "Welsh"),
        SupportedLanguage(id: "sk", name: "Slovak"),
        SupportedLanguage(id: "te", name: "Telugu"),
        SupportedLanguage(id: "fa", name: "Persian"),
        SupportedLanguage(id: "lv", name: "Latvian"),
        SupportedLanguage(id: "bn", name: "Bengali"),
        SupportedLanguage(id: "sr", name: "Serbian"),
        SupportedLanguage(id: "az", name: "Azerbaijani"),
        SupportedLanguage(id: "sl", name: "Slovenian"),
        SupportedLanguage(id: "kn", name: "Kannada"),
        SupportedLanguage(id: "et", name: "Estonian"),
        SupportedLanguage(id: "mk", name: "Macedonian"),
        SupportedLanguage(id: "br", name: "Breton"),
        SupportedLanguage(id: "eu", name: "Basque"),
        SupportedLanguage(id: "is", name: "Icelandic"),
        SupportedLanguage(id: "hy", name: "Armenian"),
        SupportedLanguage(id: "ne", name: "Nepali"),
        SupportedLanguage(id: "mn", name: "Mongolian"),
        SupportedLanguage(id: "bs", name: "Bosnian"),
        SupportedLanguage(id: "kk", name: "Kazakh"),
        SupportedLanguage(id: "sq", name: "Albanian"),
        SupportedLanguage(id: "sw", name: "Swahili"),
        SupportedLanguage(id: "gl", name: "Galician"),
        SupportedLanguage(id: "mr", name: "Marathi"),
        SupportedLanguage(id: "pa", name: "Punjabi"),
        SupportedLanguage(id: "si", name: "Sinhala"),
        SupportedLanguage(id: "km", name: "Khmer"),
        SupportedLanguage(id: "sn", name: "Shona"),
        SupportedLanguage(id: "yo", name: "Yoruba"),
        SupportedLanguage(id: "so", name: "Somali"),
        SupportedLanguage(id: "af", name: "Afrikaans"),
        SupportedLanguage(id: "oc", name: "Occitan"),
        SupportedLanguage(id: "ka", name: "Georgian"),
        SupportedLanguage(id: "be", name: "Belarusian"),
        SupportedLanguage(id: "tg", name: "Tajik"),
        SupportedLanguage(id: "sd", name: "Sindhi"),
        SupportedLanguage(id: "gu", name: "Gujarati"),
        SupportedLanguage(id: "am", name: "Amharic"),
        SupportedLanguage(id: "yi", name: "Yiddish"),
        SupportedLanguage(id: "lo", name: "Lao"),
        SupportedLanguage(id: "uz", name: "Uzbek"),
        SupportedLanguage(id: "fo", name: "Faroese"),
        SupportedLanguage(id: "ht", name: "Haitian Creole"),
        SupportedLanguage(id: "ps", name: "Pashto"),
        SupportedLanguage(id: "tk", name: "Turkmen"),
        SupportedLanguage(id: "nn", name: "Nynorsk"),
        SupportedLanguage(id: "mt", name: "Maltese"),
        SupportedLanguage(id: "sa", name: "Sanskrit"),
        SupportedLanguage(id: "lb", name: "Luxembourgish"),
        SupportedLanguage(id: "my", name: "Myanmar"),
        SupportedLanguage(id: "bo", name: "Tibetan"),
        SupportedLanguage(id: "tl", name: "Tagalog"),
        SupportedLanguage(id: "mg", name: "Malagasy"),
        SupportedLanguage(id: "as", name: "Assamese"),
        SupportedLanguage(id: "tt", name: "Tatar"),
        SupportedLanguage(id: "haw", name: "Hawaiian"),
        SupportedLanguage(id: "ln", name: "Lingala"),
        SupportedLanguage(id: "ha", name: "Hausa"),
        SupportedLanguage(id: "ba", name: "Bashkir"),
        SupportedLanguage(id: "jw", name: "Javanese"),
        SupportedLanguage(id: "su", name: "Sundanese"),
    ]
}

// MARK: - SettingsView

/// The main settings view presenting a Form with all configurable preferences.
///
/// Requirement 10.1: Preferences window with sections for Hotkey, Audio Device, Model, General.
/// Requirement 10.5: All changes apply immediately without restart.
/// Requirement 14.3: Liquid Glass materials on settings window.
/// Requirement 14.5: Semantic system colors for text and UI elements.
struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// Available audio input devices, fetched from AudioEngine.
    @State private var audioDevices: [AudioInputDevice] = []

    /// Available Whisper models, fetched from WhisperService.
    @State private var whisperModels: [WhisperModelInfo] = []

    /// Whether the hotkey recorder is actively listening for a new key combination.
    @State private var isRecordingHotkey = false

    /// Error message for hotkey conflicts.
    @State private var hotkeyError: String?

    /// The AudioEngine used to query available devices.
    private let audioEngine: AudioEngine

    /// The WhisperService used to query available models.
    private let whisperService: WhisperService

    init(audioEngine: AudioEngine, whisperService: WhisperService) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
    }

    var body: some View {
        Form {
            hotkeySection
            audioDeviceSection
            whisperModelSection
            languageSection
            generalSection
        }
        .formStyle(.grouped)
        .font(.body)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 520, idealHeight: 580)
        .liquidGlassPanel()
        .task {
            await loadAudioDevices()
            await loadWhisperModels()
        }
    }

    // MARK: - Hotkey Configuration Section

    /// Requirement 10.1: Hotkey Configuration section.
    /// Displays the current hotkey and allows recording a new one.
    private var hotkeySection: some View {
        Section {
            HStack {
                Label("Shortcut", systemImage: SFSymbols.keyboard)
                    .font(.body)
                    .foregroundStyle(theme.primaryTextColor)
                Spacer()
                HotkeyRecorderView(
                    keyCode: Bindable(settingsStore).hotkeyKeyCode,
                    modifiers: Bindable(settingsStore).hotkeyModifiers,
                    isRecording: $isRecordingHotkey,
                    errorMessage: $hotkeyError
                )
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hotkey shortcut")
            .accessibilityHint("Activate to record a new hotkey combination")

            if let error = hotkeyError {
                Label(error, systemImage: theme.actionSymbol(.warning))
                    .foregroundStyle(theme.errorColor)
                    .font(.callout)
            }
        } header: {
            Text("Hotkey Configuration")
                .font(.headline)
        }
    }

    // MARK: - Audio Device Section

    /// Requirement 8.1: Audio device picker listing available input devices.
    private var audioDeviceSection: some View {
        Section {
            @Bindable var store = settingsStore
            Picker(selection: $store.selectedAudioDeviceUID) {
                Text("System Default")
                    .tag(nil as String?)
                ForEach(audioDevices) { device in
                    Text(device.name)
                        .tag(device.uid as String?)
                }
            } label: {
                Label("Input Device", systemImage: theme.actionSymbol(.microphone))
                    .font(.body)
                    .foregroundStyle(theme.primaryTextColor)
            }
            .padding(.vertical, 4)
            .accessibilityLabel("Audio input device")
            .accessibilityHint("Select the microphone to use for recording")
        } header: {
            Text("Audio Device")
                .font(.headline)
        }
    }

    // MARK: - Whisper Model Section

    /// Requirement 10.1: Whisper Model section with picker and link to Model Management.
    private var whisperModelSection: some View {
        Section {
            @Bindable var store = settingsStore
            Picker(selection: $store.activeModelName) {
                ForEach(whisperModels) { model in
                    HStack {
                        Text(model.displayName)
                        Text("(\(model.sizeDescription))")
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    .tag(model.id)
                }
            } label: {
                Label("Active Model", systemImage: theme.actionSymbol(.model))
                    .font(.body)
                    .foregroundStyle(theme.primaryTextColor)
            }
            .padding(.vertical, 4)
            .accessibilityLabel("Whisper model")
            .accessibilityHint("Select the speech recognition model to use")
        } header: {
            Text("Whisper Model")
                .font(.headline)
        }
    }

    // MARK: - Language Section

    /// Requirements 16.3, 16.4, 16.5, 16.6, 16.9, 16.10, 16.11:
    /// Language selection with auto-detect toggle, language picker, and pin language toggle.
    private var languageSection: some View {
        Section {
            // Auto-detect toggle
            // Requirement 16.3: Default to auto-detect mode.
            // Requirement 16.11: Enabling auto-detect clears pinned language.
            Toggle(isOn: autoDetectBinding) {
                Label("Auto-Detect Language", systemImage: theme.actionSymbol(.language))
                    .foregroundStyle(theme.primaryTextColor)
            }
            .padding(.vertical, 4)
            .accessibilityLabel("Auto-detect language")
            .accessibilityHint("When enabled, Wisp automatically detects the spoken language")

            // Language picker (shown when auto-detect is off)
            // Requirement 16.4: Select a specific language for transcription.
            if !settingsStore.languageMode.isAutoDetect {
                Picker(selection: selectedLanguageCodeBinding) {
                    ForEach(SupportedLanguage.all) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                } label: {
                    Label("Language", systemImage: SFSymbols.characterBubble)
                        .foregroundStyle(theme.primaryTextColor)
                }
                .accessibilityLabel("Transcription language")
                .accessibilityHint("Select the language for speech transcription")

                // Pin language toggle
                // Requirement 16.10: Pin language disables auto-detect and locks transcription.
                Toggle(isOn: pinLanguageBinding) {
                    Label("Pin Language", systemImage: SFSymbols.pin)
                        .foregroundStyle(theme.primaryTextColor)
                }
                .padding(.vertical, 4)
                .accessibilityLabel("Pin language")
                .accessibilityHint("When enabled, locks transcription to the selected language")
            }
        } header: {
            Text("Language")
                .font(.headline)
        }
    }

    // MARK: - General Section

    /// Requirements 10.3, 10.4: Launch at Login toggle using ServiceManagement.
    private var generalSection: some View {
        Section {
            Toggle(isOn: launchAtLoginBinding) {
                Label("Launch at Login", systemImage: theme.actionSymbol(.launchAtLogin))
                    .foregroundStyle(theme.primaryTextColor)
            }
            .padding(.vertical, 4)
            .accessibilityLabel("Launch at login")
            .accessibilityHint("When enabled, Wisp starts automatically when you log in")
        } header: {
            Text("General")
                .font(.headline)
        }
    }

    // MARK: - Data Loading

    private func loadAudioDevices() async {
        audioDevices = await audioEngine.availableInputDevices()
    }

    private func loadWhisperModels() async {
        whisperModels = await whisperService.availableModels()
    }

    // MARK: - Bindings

    /// Binding for the auto-detect toggle.
    /// Requirement 16.11: Enabling auto-detect clears pinned language.
    private var autoDetectBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settingsStore.languageMode.isAutoDetect },
            set: { newValue in
                if newValue {
                    settingsStore.languageMode = .autoDetect
                } else {
                    // Default to English when disabling auto-detect
                    settingsStore.languageMode = .specific(code: "en")
                }
            }
        )
    }

    /// Binding for the selected language code.
    /// Requirement 16.5: Persist selected language.
    private var selectedLanguageCodeBinding: Binding<String> {
        Binding<String>(
            get: {
                settingsStore.languageMode.languageCode ?? "en"
            },
            set: { newCode in
                if settingsStore.languageMode.isPinned {
                    settingsStore.languageMode = .pinned(code: newCode)
                } else {
                    settingsStore.languageMode = .specific(code: newCode)
                }
            }
        )
    }

    /// Binding for the pin language toggle.
    /// Requirement 16.10: Pin language locks transcription to selected language.
    private var pinLanguageBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settingsStore.languageMode.isPinned },
            set: { newValue in
                let code = settingsStore.languageMode.languageCode ?? "en"
                if newValue {
                    settingsStore.languageMode = .pinned(code: code)
                } else {
                    settingsStore.languageMode = .specific(code: code)
                }
            }
        )
    }

    /// Binding for Launch at Login.
    /// Requirements 10.3, 10.4: Register/unregister handled by SettingsStore.
    private var launchAtLoginBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settingsStore.launchAtLogin },
            set: { newValue in
                settingsStore.launchAtLogin = newValue
            }
        )
    }
}

// MARK: - HotkeyRecorderView

/// A control that displays the current hotkey and captures a new key combination when activated.
///
/// When the user clicks "Record", the view listens for the next key event and updates
/// the hotkey key code and modifiers accordingly.
struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @Binding var isRecording: Bool
    @Binding var errorMessage: String?

    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    var body: some View {
        Button {
            isRecording.toggle()
            if !isRecording {
                errorMessage = nil
            }
        } label: {
            if isRecording {
                HStack(spacing: 4) {
                    Image(systemName: SFSymbols.recordCircle)
                        .foregroundStyle(theme.errorColor)
                    Text("Press keys…")
                        .foregroundStyle(theme.secondaryTextColor)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
            } else {
                Text(hotkeyDisplayString)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
            }
        }
        .buttonStyle(.bordered)
        .highContrastBorder(cornerRadius: 6)
        .keyboardFocusRing()
        .accessibilityLabel(isRecording ? "Recording hotkey, press desired key combination" : "Current hotkey: \(hotkeyDisplayString)")
        .accessibilityHint("Click to record a new hotkey")
        .onKeyPress(phases: .down) { keyPress in
            guard isRecording else { return .ignored }
            handleKeyPress(keyPress)
            return .handled
        }
    }

    /// Handles a key press event during hotkey recording.
    private func handleKeyPress(_ keyPress: KeyPress) {
        // Convert SwiftUI key modifiers to Carbon modifier flags
        var carbonModifiers: UInt32 = 0
        if keyPress.modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if keyPress.modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if keyPress.modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if keyPress.modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }

        // Require at least one modifier key
        guard carbonModifiers != 0 else {
            errorMessage = "Hotkey must include at least one modifier key (⌘, ⌥, ⌃, or ⇧)"
            return
        }

        // Map the key character to a virtual key code
        let newKeyCode = virtualKeyCode(from: keyPress)

        keyCode = newKeyCode
        modifiers = carbonModifiers
        isRecording = false
        errorMessage = nil
    }

    /// Maps a SwiftUI KeyPress to a Carbon virtual key code.
    private func virtualKeyCode(from keyPress: KeyPress) -> UInt32 {
        // Common key mappings from character to Carbon virtual key code
        let keyMap: [Character: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7,
            "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
            "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22,
            "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
            "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37,
            "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, " ": 49,
        ]

        if let char = keyPress.characters.lowercased().first,
           let code = keyMap[char] {
            return code
        }

        // Fallback: return Space key code
        return 49
    }

    /// Formats the current hotkey as a human-readable string (e.g., "⌥Space").
    private var hotkeyDisplayString: String {
        var parts: [String] = []

        if modifiers & UInt32(controlKey) != 0 { parts.append("⌃") }
        if modifiers & UInt32(optionKey) != 0 { parts.append("⌥") }
        if modifiers & UInt32(shiftKey) != 0 { parts.append("⇧") }
        if modifiers & UInt32(cmdKey) != 0 { parts.append("⌘") }

        let keyName = keyCodeToString(keyCode)
        parts.append(keyName)

        return parts.joined()
    }

    /// Converts a Carbon virtual key code to a display string.
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
}

// MARK: - Preview

#if DEBUG
private struct SettingsPreview: View {
    @State private var settingsStore = PreviewMocks.makeSettingsStore()
    @State private var theme = PreviewMocks.makeTheme()

    var body: some View {
        SettingsView(
            audioEngine: PreviewMocks.makeAudioEngine(),
            whisperService: PreviewMocks.makeWhisperService()
        )
        .environment(settingsStore)
        .environment(theme)
        .frame(width: 560, height: 580)
    }
}

#Preview("Settings") {
    SettingsPreview()
}
#endif
