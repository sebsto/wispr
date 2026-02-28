//
//  SettingsView.swift
//  wispr
//
//  SwiftUI settings view with sections for Hotkey Configuration,
//  Audio Device, Whisper Model, Language, and General.
//

import SwiftUI

// MARK: - Reusable Components

private struct SectionHeader: View {
    let title: String
    let systemImage: String
    let tint: Color

    @ScaledMetric(relativeTo: .headline) private var iconSize = 18.0

    var body: some View {
        Label {
            Text(title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .foregroundStyle(tint.gradient)
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    @State private var audioDevices: [AudioInputDevice] = []
    @State private var whisperModels: [WhisperModelInfo] = []
    @State private var isRecordingHotkey = false
    @State private var hotkeyError: String?

    private let audioEngine: AudioEngine
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
        .scrollDisabled(true)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .liquidGlassPanel()
        .task {
            await loadAudioDevices()
            await loadWhisperModels()
        }
    }

    // MARK: - Hotkey Configuration Section

    private var hotkeySection: some View {
        Section {
            LabeledContent("Shortcut") {
                HotkeyRecorderView(
                    keyCode: Bindable(settingsStore).hotkeyKeyCode,
                    modifiers: Bindable(settingsStore).hotkeyModifiers,
                    isRecording: $isRecordingHotkey,
                    errorMessage: $hotkeyError
                )
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Hotkey shortcut")
            .accessibilityHint("Activate to record a new hotkey combination")

            if let error = hotkeyError {
                Label(error, systemImage: theme.actionSymbol(.warning))
                    .foregroundStyle(theme.errorColor)
                    .font(.callout)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        } header: {
            SectionHeader(
                title: "Hotkey Configuration",
                systemImage: SFSymbols.keyboard,
                tint: .orange
            )
        }
        .motionRespectingAnimation(value: hotkeyError)
    }

    // MARK: - Audio Device Section

    private var audioDeviceSection: some View {
        Section {
            if audioDevices.isEmpty {
                Text("No audio input devices found")
                    .foregroundStyle(.secondary)
            } else {
                @Bindable var store = settingsStore
                Picker("Input Device", selection: $store.selectedAudioDeviceUID) {
                    Text("System Default")
                        .tag(nil as String?)
                    ForEach(audioDevices) { device in
                        Text(device.name)
                            .tag(device.uid as String?)
                    }
                }
                .accessibilityHint("Select the microphone to use for recording")
            }
        } header: {
            SectionHeader(
                title: "Audio Device",
                systemImage: theme.actionSymbol(.microphone),
                tint: .blue
            )
        }
    }

    // MARK: - Whisper Model Section

    private var availableModels: [WhisperModelInfo] {
        whisperModels.filter { $0.status == .downloaded || $0.status == .active }
    }

    private var whisperModelSection: some View {
        Section {
            if availableModels.isEmpty {
                Text("No models downloaded")
                    .foregroundStyle(.secondary)
            } else {
                @Bindable var store = settingsStore
                Picker("Active Model", selection: $store.activeModelName) {
                    ForEach(availableModels) { model in
                        HStack {
                            Text(model.displayName)
                            Text("(\(model.sizeDescription))")
                                .foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }
                .accessibilityHint("Select the speech recognition model to use")
            }
        } header: {
            SectionHeader(
                title: "Whisper Model",
                systemImage: theme.actionSymbol(.model),
                tint: .purple
            )
        }
    }

    // MARK: - Language Section

    private var languageSection: some View {
        Section {
            Toggle("Auto-Detect Language", isOn: autoDetectBinding)
                .accessibilityHint("When enabled, Wisp automatically detects the spoken language")

            if !settingsStore.languageMode.isAutoDetect {
                Picker("Language", selection: selectedLanguageCodeBinding) {
                    ForEach(SupportedLanguage.all) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }
                .accessibilityHint("Select the language for speech transcription")

                Toggle("Always use this language", isOn: pinLanguageBinding)
                    .accessibilityHint("When enabled, always transcribes in the selected language instead of detecting per-recording")
            }
        } header: {
            SectionHeader(
                title: "Language",
                systemImage: theme.actionSymbol(.language),
                tint: .green
            )
        }
        .motionRespectingAnimation(value: settingsStore.languageMode.isAutoDetect)
    }

    // MARK: - General Section

    private var generalSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Show Recording Overlay", isOn: $store.showRecordingOverlay)
                .accessibilityHint("When enabled, a floating overlay appears while recording")

            Toggle("Launch at Login", isOn: $store.launchAtLogin)
                .accessibilityHint("When enabled, Wisp starts automatically when you log in")
        } header: {
            SectionHeader(
                title: "General",
                systemImage: SFSymbols.settings,
                tint: .secondary
            )
        }
    }

    // MARK: - Data Loading

    private func loadAudioDevices() async {
        audioDevices = await audioEngine.availableInputDevices()
    }

    private func loadWhisperModels() async {
        var models = await whisperService.availableModels()
        for index in models.indices {
            models[index].status = await whisperService.modelStatus(models[index].id)
        }
        whisperModels = models
    }

    // MARK: - Bindings

    /// Manual binding because toggling auto-detect has side effects:
    /// enabling it clears the language selection, disabling it defaults to English.
    private var autoDetectBinding: Binding<Bool> {
        Binding<Bool>(
            get: { settingsStore.languageMode.isAutoDetect },
            set: { newValue in
                withAnimation(theme.standardSpringAnimation) {
                    if newValue {
                        settingsStore.languageMode = .autoDetect
                    } else {
                        settingsStore.languageMode = .specific(code: "en")
                    }
                }
            }
        )
    }

    /// Manual binding because changing the language code must preserve the
    /// current pinned/specific mode.
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

    /// Manual binding because toggling pin must preserve the currently
    /// selected language code.
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
    }
}

#Preview("Settings") {
    SettingsPreview()
}

#Preview("Settings - Dark") {
    SettingsPreview()
        .preferredColorScheme(.dark)
}
#endif
