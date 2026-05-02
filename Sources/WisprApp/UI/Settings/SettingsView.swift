//
//  SettingsView.swift
//  wispr
//
//  SwiftUI settings view with sections for Shortcut, Audio Device,
//  Recognition, After Transcription, Feedback, and General.
//

import WisprCore
import SwiftUI
import os

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

    // MARK: Accessibility Hints

    /// Shared hint strings so tests can assert against the same values the view uses.
    enum AccessibilityHints {
        // Shortcut section
        static let hotkeyShortcut = "Activate to record a new hotkey combination"
        static let handsFreeMode = "When enabled, press the hotkey once to start recording and again to stop. When disabled, hold the hotkey to record."

        // Audio Device section
        static let inputDevice = "Select the microphone to use for recording"

        // Recognition section
        static let activeModel = "Select the speech recognition model to use"
        static let autoDetectLanguage = "When enabled, Wispr automatically detects the spoken language"
        static let languagePicker = "Select the language for speech transcription"
        static let alwaysUseLanguage = "When enabled, always transcribes in the selected language instead of detecting per-recording"

        // After Transcription section
        static let removeFillerWords = "When enabled, removes filler words like um, uh, and ah from transcriptions"
        static let aiTextCorrection = "When enabled, uses on-device AI to correct grammar and improve transcription fluency. All processing stays on your Mac."
        static let autoInsertSuffix = "When enabled, appends a suffix to transcribed text"
        static let autoSendEnter = "When enabled, simulates pressing Enter after text insertion"

        // Feedback section
        static let soundFeedback = "When enabled, plays audio cues when recording starts and stops"
        static let showRecordingOverlay = "When enabled, a floating overlay appears while recording"

        // General section
        static let launchAtLogin = "When enabled, Wispr starts automatically when you log in"
        static let restoreDefaults = "Resets all settings to their original values"
    }
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @Environment(UpdateChecker.self) private var updateChecker: UpdateChecker
    @Environment(StateManager.self) private var stateManager: StateManager
    @Environment(HotkeyMonitor.self) private var hotkeyMonitor: HotkeyMonitor
    @Environment(TextCorrectionService.self) private var textCorrectionService: TextCorrectionService

    @State private var audioDevices: [AudioInputDevice] = []
    @State private var whisperModels: [ModelInfo] = []
    @State private var isRecordingHotkey = false
    @State private var hotkeyError: String?
    @State private var showRestoreDefaultsAlert = false

    /// The model ID currently being activated from the Settings picker.
    @State private var activatingModelId: String?

    /// Local selection state for the model picker, synced via .onChange/.task.
    @State private var selectedModelId: String = ""

    private let audioEngine: AudioEngine
    private let whisperService: any TranscriptionEngine

    init(audioEngine: AudioEngine, whisperService: any TranscriptionEngine) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
    }

    var body: some View {
        Form {
            shortcutSection
            audioDeviceSection
            recognitionSection
            afterTranscriptionSection
            feedbackSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(maxHeight: 600)
        .liquidGlassPanel()
        .alert("Restore Defaults?", isPresented: $showRestoreDefaultsAlert) {
            Button("Restore", role: .destructive, action: restoreDefaults)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("All settings will be reset to their original values. This cannot be undone.")
        }
        .task {
            selectedModelId = settingsStore.activeModelName
            await loadAudioDevices()
            await loadWhisperModels()
        }
        .onChange(of: isRecordingHotkey) { _, recording in
            if recording {
                hotkeyMonitor.unregister()
            } else {
                do {
                    try hotkeyMonitor.register(
                        keyCode: settingsStore.hotkeyKeyCode,
                        modifiers: settingsStore.hotkeyModifiers
                    )
                    hotkeyError = nil
                } catch {
                    hotkeyError = error.localizedDescription
                    Log.hotkey.error("Settings — failed to re-register hotkey: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Shortcut Section

    private var shortcutSection: some View {
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
            .accessibilityHint(AccessibilityHints.hotkeyShortcut)

            if let error = hotkeyError {
                Label(error, systemImage: theme.actionSymbol(.warning))
                    .foregroundStyle(theme.errorColor)
                    .font(.callout)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if settingsStore.hotkeyKeyCode == HotkeyMonitor.fnKeyCode
                && settingsStore.hotkeyModifiers == 0 {
                Label {
                    Text("The Globe key may conflict with macOS features like the emoji picker or input source switching. If dictation doesn't start, go to System Settings → Keyboard → \"Press 🌐 key to\" and select \"Do Nothing\".")
                } icon: {
                    Image(systemName: SFSymbols.info)
                        .foregroundStyle(.blue)
                }
                .font(.caption)
            }

            @Bindable var store = settingsStore
            Toggle("Hands-Free Mode", isOn: $store.handsFreeMode)
                .accessibilityHint(AccessibilityHints.handsFreeMode)

        } header: {
            SectionHeader(
                title: "Shortcut",
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
                .accessibilityHint(AccessibilityHints.inputDevice)
            }
        } header: {
            SectionHeader(
                title: "Audio Device",
                systemImage: theme.actionSymbol(.microphone),
                tint: .blue
            )
        }
    }

    // MARK: - Recognition Section

    private var availableModels: [ModelInfo] {
        whisperModels.filter { $0.status == .downloaded || $0.status == .active }
    }

    private var recognitionSection: some View {
        Section {
            if availableModels.isEmpty {
                Text("No models downloaded")
                    .foregroundStyle(.secondary)
            } else {
                Picker("Active Model", selection: $selectedModelId) {
                    ForEach(availableModels) { model in
                        HStack {
                            Text(model.displayName)
                            Text("(\(model.sizeDescription))")
                                .foregroundStyle(.secondary)
                        }
                        .tag(model.id)
                    }
                }
                .disabled(activatingModelId != nil)
                .overlay(alignment: .trailing) {
                    if activatingModelId != nil {
                        ProgressView()
                            .controlSize(.small)
                            .padding(.trailing, 4)
                    }
                }
                .accessibilityHint(AccessibilityHints.activeModel)
                .onChange(of: selectedModelId) { _, newModelId in
                    guard newModelId != settingsStore.activeModelName,
                          !newModelId.isEmpty else { return }
                    activatingModelId = newModelId
                }
                .task(id: activatingModelId) {
                    guard let modelId = activatingModelId else { return }
                    do {
                        try await stateManager.switchActiveModel(to: modelId)
                    } catch {
                        selectedModelId = settingsStore.activeModelName
                    }
                    await loadWhisperModels()
                    activatingModelId = nil
                }
                .onChange(of: settingsStore.activeModelName) { _, newName in
                    guard activatingModelId == nil else { return }
                    selectedModelId = newName
                }
            }

            Toggle("Auto-Detect Language", isOn: autoDetectBinding)
                .accessibilityHint(AccessibilityHints.autoDetectLanguage)

            if !settingsStore.languageMode.isAutoDetect {
                Picker("Language", selection: selectedLanguageCodeBinding) {
                    ForEach(SupportedLanguage.all) { lang in
                        Text(lang.name).tag(lang.id)
                    }
                }
                .accessibilityHint(AccessibilityHints.languagePicker)

                Toggle("Always use this language", isOn: pinLanguageBinding)
                    .accessibilityHint(AccessibilityHints.alwaysUseLanguage)
            }
        } header: {
            SectionHeader(
                title: "Recognition",
                systemImage: theme.actionSymbol(.model),
                tint: .purple
            )
        }
        .motionRespectingAnimation(value: settingsStore.languageMode.isAutoDetect)
    }

    // MARK: - After Transcription Section

    private var afterTranscriptionSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Remove Filler Words", isOn: $store.removeFillerWords)
                .accessibilityHint(AccessibilityHints.removeFillerWords)

            Toggle("Local AI Text Correction", isOn: $store.aiTextCorrectionEnabled)
                .disabled(textCorrectionService.availability != .available)
                .accessibilityHint(AccessibilityHints.aiTextCorrection)
                .onAppear { textCorrectionService.checkAvailability() }

            if case .notAvailable(let reason) = textCorrectionService.availability {
                Label(reason, systemImage: SFSymbols.info)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Correction style picker hidden — fullRephrase mode not reliable with
            // Apple's on-device model (interprets input as instructions instead of
            // correcting it). Keeping the code for when the model improves.
            // if settingsStore.aiTextCorrectionEnabled, textCorrectionService.availability == .available {
            //     Picker("Correction Style", selection: $store.aiTextCorrectionStyle) {
            //         ForEach(CorrectionStyle.allCases, id: \.self) { style in
            //             Text(style.displayName).tag(style)
            //         }
            //     }
            // }

            Toggle("Auto-Insert Suffix", isOn: $store.autoSuffixEnabled)
                .accessibilityHint(AccessibilityHints.autoInsertSuffix)

            if settingsStore.autoSuffixEnabled {
                LabeledContent("Suffix") {
                    SuffixEditorView(suffixText: $store.autoSuffixText)
                }
            }

            Toggle("Auto-Send Enter", isOn: $store.autoSendEnterEnabled)
                .accessibilityHint(AccessibilityHints.autoSendEnter)
        } header: {
            SectionHeader(
                title: "After Transcription",
                systemImage: SFSymbols.textOutput,
                tint: .teal
            )
        }
        .motionRespectingAnimation(value: settingsStore.autoSuffixEnabled)
        .motionRespectingAnimation(value: settingsStore.aiTextCorrectionEnabled)
    }

    // MARK: - Feedback Section

    private var feedbackSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Sound Feedback", isOn: $store.soundFeedbackEnabled)
                .accessibilityHint(AccessibilityHints.soundFeedback)

            Toggle("Show Recording Overlay", isOn: $store.showRecordingOverlay)
                .accessibilityHint(AccessibilityHints.showRecordingOverlay)
        } header: {
            SectionHeader(
                title: "Feedback",
                systemImage: SFSymbols.feedback,
                tint: .mint
            )
        }
    }

    // MARK: - General Section

    private var generalSection: some View {
        Section {
            @Bindable var store = settingsStore
            Toggle("Launch at Login", isOn: $store.launchAtLogin)
                .accessibilityHint(AccessibilityHints.launchAtLogin)

            HStack {
                Text("Version")
                    .foregroundStyle(theme.primaryTextColor)
                Spacer()
                Text(appVersion)
                    .foregroundStyle(theme.secondaryTextColor)
                    .font(.callout)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Version \(appVersion)")

            if let update = updateChecker.availableUpdate {
                HStack {
                    Label("Version \(update.version) available", systemImage: SFSymbols.download)
                        .foregroundStyle(.tint)
                        .font(.callout)
                    Spacer()
                    Link("Download", destination: update.downloadURL)
                        .font(.callout)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Version \(update.version) available. Activate to download.")
            }

            Button("Restore Defaults") {
                showRestoreDefaultsAlert = true
            }
            .accessibilityHint(AccessibilityHints.restoreDefaults)
        } header: {
            SectionHeader(
                title: "General",
                systemImage: SFSymbols.settings,
                tint: .secondary
            )
        }
    }
    
    // MARK: - Version Info
    
    /// Returns the app version string in the format "1.0.0 (123)" where 123 is the build number.
    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "Unknown"
        return "\(version) (\(build))"
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

    // MARK: - Restore Defaults

    private func restoreDefaults() {
        settingsStore.restoreDefaults()
        hotkeyError = nil
        isRecordingHotkey = false
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
    @State private var settingsStore: SettingsStore
    @State private var theme = PreviewMocks.makeTheme()
    @State private var updateChecker = PreviewMocks.makeUpdateChecker()
    @State private var stateManager: StateManager
    @State private var textCorrectionService = TextCorrectionService()

    private let whisperService: any TranscriptionEngine

    init(
        autoSuffixEnabled: Bool = false,
        autoSendEnterEnabled: Bool = false,
        languageSpecific: Bool = false,
        languagePinned: Bool = false
    ) {
        let store = PreviewMocks.makeSettingsStore()
        store.autoSuffixEnabled = autoSuffixEnabled
        store.autoSendEnterEnabled = autoSendEnterEnabled
        if languagePinned {
            store.languageMode = .pinned(code: "en")
        } else if languageSpecific {
            store.languageMode = .specific(code: "en")
        }
        self._settingsStore = State(initialValue: store)

        let service = PreviewMocks.makeWhisperService()
        self.whisperService = service
        self._stateManager = State(initialValue: PreviewMocks.makeStateManager(
            settingsStore: store,
            whisperService: service
        ))
    }

    var body: some View {
        SettingsView(
            audioEngine: PreviewMocks.makeAudioEngine(),
            whisperService: whisperService
        )
        .environment(settingsStore)
        .environment(theme)
        .environment(updateChecker)
        .environment(stateManager)
        .environment(HotkeyMonitor())
        .environment(textCorrectionService)
    }
}

#Preview("Settings") {
    SettingsPreview()
}

#Preview("Settings - Dark") {
    SettingsPreview()
        .preferredColorScheme(.dark)
}

#Preview("Settings - Suffix & Language Expanded") {
    SettingsPreview(autoSuffixEnabled: true, languageSpecific: true)
}

#Preview("Settings - All Toggles On") {
    SettingsPreview(
        autoSuffixEnabled: true,
        autoSendEnterEnabled: true,
        languageSpecific: true,
        languagePinned: true
    )
}
#endif
