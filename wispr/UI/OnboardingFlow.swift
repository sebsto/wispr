//
//  OnboardingFlow.swift
//  wispr
//
//  Multi-step onboarding wizard presented on first launch.
//  Requirements: 13.1, 13.2, 13.13, 14.3, 14.8, 14.12
//

import SwiftUI

/// Multi-step onboarding wizard that guides the user through initial setup.
///
/// Steps: Welcome → Microphone Permission → Accessibility Permission →
/// Model Selection → Test Dictation → Completion.
///
/// Resumes from the last incomplete step if the user force-quit during onboarding.
struct OnboardingFlow: View {
    @Environment(PermissionManager.self) private var permissionManager: PermissionManager
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @Environment(StateManager.self) private var stateManager: StateManager

    /// The WhisperService actor used for model operations during onboarding.
    /// Passed as a regular property because actors are not Observable.
    let whisperService: WhisperService

    /// Closure invoked when onboarding is complete and the window should close.
    /// The parent view or window controller sets this to dismiss the onboarding window.
    var onDismiss: (() -> Void)?

    // MARK: - State

    /// The current onboarding step
    @State private var currentStep: OnboardingStep = .welcome

    /// Direction of the step transition for animation
    @State private var transitionDirection: TransitionDirection = .forward

    /// Whether the view has performed initial resume logic
    @State private var hasResumed = false

    // MARK: - Model Selection State (Req 13.6, 13.7, 13.8, 13.15)

    /// The list of available models fetched from WhisperService
    @State private var availableModels: [WhisperModelInfo] = []

    /// The ID of the model the user has selected for download
    @State private var selectedModelId: String?

    /// Current download progress (0.0–1.0)
    @State private var downloadProgress: Double = 0

    /// Total bytes for the current download (for display)
    @State private var downloadTotalBytes: Int64 = 0

    /// Bytes downloaded so far
    @State private var downloadedBytes: Int64 = 0

    /// Whether a model download is in progress
    @State private var isDownloading = false

    /// Error message from a failed download
    @State private var downloadError: String?

    /// Whether a model download has completed successfully
    @State private var downloadComplete = false

    // MARK: - Test Dictation State (Req 13.9, 13.10)

    /// The transcribed text from the test dictation, if any.
    @State private var testTranscriptionResult: String = ""

    /// Whether the user is currently recording during the test dictation.
    @State private var isTestRecording = false

    /// Whether the test dictation is being processed (transcription in progress).
    @State private var isTestProcessing = false

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            stepIndicator
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(currentStep)

            Divider()

            navigationBar
                .padding(20)
        }
        .frame(width: 540, height: 460)
        .liquidGlassPanel()
        .highContrastBorder(cornerRadius: 12)
        .motionRespectingAnimation(value: currentStep)
        .task {
            resumeFromLastStep()
        }
        .onChange(of: currentStep) { _, newStep in
            settingsStore.onboardingLastStep = newStep.rawValue
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wisp Setup")
    }

    // MARK: - Step Indicator

    /// Displays dots representing each step with the current step highlighted.
    private var stepIndicator: some View {
        VStack(spacing: 8) {
            Text("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .accessibilityLabel("Step \(currentStep.rawValue + 1) of \(OnboardingStep.allCases.count)")

            HStack(spacing: 8) {
                ForEach(OnboardingStep.allCases, id: \.rawValue) { step in
                    Circle()
                        .fill(dotColor(for: step))
                        .frame(width: 8, height: 8)
                        .scaleEffect(step == currentStep ? 1.3 : 1.0)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    // MARK: - Step Content

    /// Placeholder content for each step. Actual implementations will be added in tasks 18.2–18.5.
    private var stepContent: some View {
        VStack(spacing: 16) {
            switch currentStep {
            case .welcome:
                welcomeStepContent
            case .microphonePermission:
                microphonePermissionStepContent
            case .accessibilityPermission:
                accessibilityPermissionStepContent
            case .modelSelection:
                modelSelectionStepContent
            case .testDictation:
                testDictationStepContent
            case .completion:
                completionStepContent
            }
        }
        .padding(24)
    }

    // MARK: - Welcome Step

    private var welcomeStepContent: some View {
        VStack(spacing: 16) {
            Image(systemName: SFSymbols.onboardingWelcome)
                .font(.system(size: 56))
                .foregroundStyle(theme.accentColor)
                .accessibilityHidden(true)

            Text("Welcome to Wisp")
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp lets you dictate text anywhere on your Mac using a global hotkey. All transcription happens on-device — your voice never leaves your computer.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome to Wisp. Dictate text anywhere on your Mac. All transcription happens on-device.")
    }

    // MARK: - Microphone Permission Step

    /// Microphone permission step with explanation and request button.
    /// Requirements: 13.3, 13.4, 13.5
    private var microphonePermissionStepContent: some View {
        VStack(spacing: 20) {
            Image(systemName: theme.actionSymbol(.microphone))
                .font(.system(size: 48))
                .foregroundStyle(permissionManager.microphoneStatus == .authorized ? theme.successColor : theme.accentColor)
                .accessibilityHidden(true)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp uses your microphone to listen to your voice and transcribe it into text. Audio is processed entirely on your Mac and never sent anywhere.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if permissionManager.microphoneStatus == .authorized {
                Label("Microphone Access Granted", systemImage: theme.actionSymbol(.checkmark))
                    .font(.headline)
                    .foregroundStyle(theme.successColor)
                    .accessibilityLabel("Microphone access granted")
            } else {
                Button {
                    Task {
                        await permissionManager.requestMicrophoneAccess()
                    }
                } label: {
                    Label("Grant Microphone Access", systemImage: theme.actionSymbol(.microphone))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .minimumTouchTarget()
                .accessibilityLabel("Grant Microphone Access")
                .accessibilityHint("Opens the system dialog to allow microphone access")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Microphone Permission step")
    }

    // MARK: - Accessibility Permission Step

    /// Accessibility permission step with explanation and system settings link.
    /// Requirements: 13.3, 13.4, 13.5
    private var accessibilityPermissionStepContent: some View {
        VStack(spacing: 20) {
            Image(systemName: theme.actionSymbol(.accessibility))
                .font(.system(size: 48))
                .foregroundStyle(permissionManager.accessibilityStatus == .authorized ? theme.successColor : theme.accentColor)
                .accessibilityHidden(true)

            Text("Accessibility Access")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp needs accessibility access to insert transcribed text directly at your cursor position in any application. This permission must be granted in System Settings.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if permissionManager.accessibilityStatus == .authorized {
                Label("Accessibility Access Granted", systemImage: theme.actionSymbol(.checkmark))
                    .font(.headline)
                    .foregroundStyle(theme.successColor)
                    .accessibilityLabel("Accessibility access granted")
            } else {
                Button {
                    permissionManager.openAccessibilitySettings()
                } label: {
                    Label("Open System Settings", systemImage: SFSymbols.settings)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .minimumTouchTarget()
                .accessibilityLabel("Open System Settings")
                .accessibilityHint("Opens System Settings to the Accessibility privacy pane")

                Text("After enabling Wisp in System Settings, return here to continue.")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accessibility Permission step")
    }

    // MARK: - Model Selection Step (Req 13.6, 13.7, 13.8, 13.15)

    /// Model selection step with model list, download progress, and error handling.
    private var modelSelectionStepContent: some View {
        VStack(spacing: 16) {
            Image(systemName: theme.actionSymbol(.model))
                .font(.system(size: 48))
                .foregroundStyle(downloadComplete ? theme.successColor : theme.accentColor)
                .accessibilityHidden(true)

            Text("Choose a Model")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Select a Whisper model to download. Smaller models are faster; larger models are more accurate.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            if downloadComplete {
                // Download completed successfully
                Label("Model Downloaded", systemImage: theme.actionSymbol(.checkmark))
                    .font(.headline)
                    .foregroundStyle(theme.successColor)
                    .accessibilityLabel("Model downloaded successfully")
            } else if isDownloading {
                // Download in progress — show progress bar
                modelDownloadProgressView
            } else if let error = downloadError {
                // Download failed — show error with retry (Req 13.15)
                modelDownloadErrorView(error: error)
            } else {
                // Model list for selection
                modelListView
            }
        }
        .task {
            await loadAvailableModels()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model Selection step")
    }

    /// List of available models for the user to pick from.
    private var modelListView: some View {
        VStack(spacing: 8) {
            ForEach(availableModels) { model in
                modelRow(model)
            }

            if selectedModelId != nil {
                Button {
                    startModelDownload()
                } label: {
                    Label("Download", systemImage: theme.actionSymbol(.download))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .minimumTouchTarget()
                .padding(.top, 8)
                .accessibilityLabel("Download selected model")
                .accessibilityHint("Downloads the selected Whisper model to your Mac")
            }
        }
    }

    /// A single row in the model list.
    private func modelRow(_ model: WhisperModelInfo) -> some View {
        let isSelected = selectedModelId == model.id
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.headline)
                    .foregroundStyle(theme.primaryTextColor)
                Text("\(model.sizeDescription) · \(model.qualityDescription)")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
            Spacer()
            if isSelected {
                Image(systemName: theme.actionSymbol(.checkmark))
                    .foregroundStyle(theme.accentColor)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
        )
        .highContrastBorder(cornerRadius: 8)
        .contentShape(Rectangle())
        .onTapGesture {
            selectedModelId = model.id
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.displayName), \(model.sizeDescription), \(model.qualityDescription)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint("Tap to select this model")
    }

    /// Real-time download progress display (Req 13.7).
    private var modelDownloadProgressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: downloadProgress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(downloadProgress * 100)) percent")

            Text("\(Int(downloadProgress * 100))% — \(formattedBytes(downloadedBytes)) of \(formattedBytes(downloadTotalBytes))")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .accessibilityHidden(true)
        }
    }

    /// Error display with retry button (Req 13.15).
    private func modelDownloadErrorView(error: String) -> some View {
        VStack(spacing: 12) {
            Label("Download Failed", systemImage: theme.actionSymbol(.warning))
                .font(.headline)
                .foregroundStyle(theme.errorColor)

            Text(error)
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)

            Button {
                downloadError = nil
                startModelDownload()
            } label: {
                Label("Retry", systemImage: SFSymbols.retry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .minimumTouchTarget()
            .accessibilityLabel("Retry download")
            .accessibilityHint("Attempts to download the model again")
        }
    }

    // MARK: - Model Download Logic

    /// Loads the available models from WhisperService.
    private func loadAvailableModels() async {
        let models = await whisperService.availableModels()
        availableModels = models
        // Pre-select the first model if nothing is selected
        if selectedModelId == nil, let first = models.first {
            selectedModelId = first.id
        }
    }

    /// Starts downloading the selected model and tracks progress.
    private func startModelDownload() {
        guard let modelId = selectedModelId,
              let model = availableModels.first(where: { $0.id == modelId }) else { return }

        isDownloading = true
        downloadProgress = 0
        downloadedBytes = 0
        downloadTotalBytes = 0
        downloadError = nil
        downloadComplete = false

        Task {
            do {
                let stream = await whisperService.downloadModel(model)
                for try await progress in stream {
                    downloadProgress = progress.fractionCompleted
                    downloadedBytes = progress.bytesDownloaded
                    downloadTotalBytes = progress.totalBytes
                }
                // Download finished successfully — set model as active in SettingsStore
                settingsStore.activeModelName = modelId
                downloadComplete = true
            } catch {
                downloadError = error.localizedDescription
            }
            isDownloading = false
        }
    }

    /// Formats byte counts into a human-readable string.
    private func formattedBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    // MARK: - Test Dictation Step (Req 13.9, 13.10)

    /// Test dictation step where the user can try the hotkey and see transcribed text.
    ///
    /// Observes `StateManager.appState` to track recording/processing states and
    /// captures the transcription result when the cycle completes.
    private var testDictationStepContent: some View {
        VStack(spacing: 20) {
            Image(systemName: SFSymbols.onboardingTestDictation)
                .font(.system(size: 48))
                .foregroundStyle(testDictationIconColor)
                .symbolEffect(.variableColor.iterative, isActive: isTestRecording && !theme.reduceMotion)
                .accessibilityHidden(true)

            Text("Test Dictation")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Press ⌥Space (Option + Space), speak a short phrase, then release to see your transcription.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            // State-dependent content
            if isTestProcessing {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Processing speech")

                Text("Transcribing…")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            } else if isTestRecording {
                HStack(spacing: 8) {
                    Circle()
                        .fill(theme.errorColor)
                        .frame(width: 10, height: 10)
                    Text("Recording…")
                        .font(.headline)
                        .foregroundStyle(theme.primaryTextColor)
                }
                .accessibilityLabel("Recording in progress")
            } else if !testTranscriptionResult.isEmpty {
                // Show the transcribed text
                VStack(spacing: 8) {
                    Label("Transcription", systemImage: theme.actionSymbol(.checkmark))
                        .font(.headline)
                        .foregroundStyle(theme.successColor)

                    Text(testTranscriptionResult)
                        .font(.body)
                        .foregroundStyle(theme.primaryTextColor)
                        .padding(12)
                        .frame(maxWidth: 400, minHeight: 60, alignment: .topLeading)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(theme.accentColor.opacity(0.08))
                        )
                        .accessibilityLabel("Transcribed text: \(testTranscriptionResult)")
                }
            } else {
                // Idle — prompt the user to try
                Text("Press the hotkey to begin")
                    .font(.caption)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .onChange(of: stateManager.appState) { _, newState in
            handleTestDictationStateChange(newState)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Test Dictation step")
    }

    /// The icon color for the test dictation step, reflecting the current state.
    private var testDictationIconColor: Color {
        if !testTranscriptionResult.isEmpty {
            return theme.successColor
        } else if isTestRecording {
            return theme.errorColor
        } else if isTestProcessing {
            return theme.accentColor
        } else {
            return theme.accentColor
        }
    }

    /// Reacts to StateManager app state changes during the test dictation step.
    ///
    /// Tracks recording → processing → idle transitions and captures the
    /// transcription result when the cycle completes.
    private func handleTestDictationStateChange(_ newState: AppStateType) {
        guard currentStep == .testDictation else { return }

        switch newState {
        case .recording:
            isTestRecording = true
            isTestProcessing = false
        case .processing:
            isTestRecording = false
            isTestProcessing = true
        case .idle:
            // If we were processing, the cycle completed — check for a result
            if isTestProcessing {
                // The StateManager doesn't expose the transcription result directly,
                // but a successful idle transition after processing means text was inserted.
                // We capture a confirmation message since the actual text goes to the cursor.
                if testTranscriptionResult.isEmpty {
                    testTranscriptionResult = "Dictation successful! Text was inserted at your cursor."
                }
            }
            isTestRecording = false
            isTestProcessing = false
        case .error(let message):
            isTestRecording = false
            isTestProcessing = false
            // Don't overwrite a successful result with an error
            if testTranscriptionResult.isEmpty {
                testTranscriptionResult = ""
            }
            _ = message // Error is shown by the StateManager's own overlay
        }
    }

    // MARK: - Completion Step

    private var completionStepContent: some View {
        VStack(spacing: 16) {
            Image(systemName: SFSymbols.onboardingComplete)
                .font(.system(size: 56))
                .foregroundStyle(theme.successColor)
                .accessibilityHidden(true)

            Text("You're All Set!")
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp is configured and ready to use. Press ⌥Space to start dictating at any time.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup complete. Wisp is ready. Press Option Space to start dictating.")
    }

    // MARK: - Placeholder Step Content

    private func placeholderStepContent(icon: String, title: String, description: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48))
                .foregroundStyle(theme.accentColor)
                .accessibilityHidden(true)

            Text(title)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text(description)
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(description)")
    }

    // MARK: - Navigation Bar

    /// Bottom bar with Back and Continue/Skip/Done buttons.
    private var navigationBar: some View {
        HStack {
            // Back button (hidden on first step)
            if currentStep != .welcome {
                Button(action: goBack) {
                    Label("Back", systemImage: SFSymbols.chevronLeft)
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(theme.secondaryTextColor)
                .minimumTouchTarget()
                .accessibilityLabel("Go back to previous step")
                .accessibilityHint("Returns to the previous onboarding step")
            }

            Spacer()

            if currentStep == .completion {
                Button("Done") {
                    completeOnboarding()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .minimumTouchTarget()
                .accessibilityLabel("Done")
                .accessibilityHint("Completes setup and closes the onboarding window")
            } else if currentStep.isSkippable && !isCurrentStepComplete {
                HStack(spacing: 12) {
                    Button("Skip") {
                        goForward()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryTextColor)
                    .minimumTouchTarget()
                    .accessibilityLabel("Skip this step")
                    .accessibilityHint("Skips the test dictation step")

                    Button("Continue") {
                        goForward()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .minimumTouchTarget()
                    .disabled(!isCurrentStepComplete)
                    .accessibilityLabel("Continue")
                    .accessibilityHint(isCurrentStepComplete ? "Proceeds to the next step" : "Complete this step to continue")
                }
            } else {
                Button("Continue") {
                    goForward()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .minimumTouchTarget()
                .disabled(!isCurrentStepComplete)
                .accessibilityLabel("Continue")
                .accessibilityHint(isCurrentStepComplete ? "Proceeds to the next step" : "Complete this step to continue")
            }
        }
    }

    // MARK: - Step Completion Logic

    /// Whether the current step's requirements are satisfied so Continue can be enabled.
    private var isCurrentStepComplete: Bool {
        switch currentStep {
        case .welcome:
            return true
        case .microphonePermission:
            return permissionManager.microphoneStatus == .authorized
        case .accessibilityPermission:
            return permissionManager.accessibilityStatus == .authorized
        case .modelSelection:
            // Req 13.8: Continue disabled until download completes successfully
            return downloadComplete
        case .testDictation:
            // Skippable step — complete when a transcription result exists
            return !testTranscriptionResult.isEmpty
        case .completion:
            return true
        }
    }

    // MARK: - Navigation

    private func goForward() {
        guard let nextStep = OnboardingStep(rawValue: currentStep.rawValue + 1) else { return }
        transitionDirection = .forward
        currentStep = nextStep
    }

    private func goBack() {
        guard let previousStep = OnboardingStep(rawValue: currentStep.rawValue - 1) else { return }
        transitionDirection = .backward
        currentStep = previousStep
    }

    private func completeOnboarding() {
        settingsStore.onboardingCompleted = true
        settingsStore.onboardingLastStep = 0
        onDismiss?()
    }

    // MARK: - Resume Logic (Req 13.14)

    /// Resumes from the last incomplete required step if the user force-quit during onboarding.
    ///
    /// If the saved step is a required step that's already complete (e.g., permissions were
    /// granted between launches), advances to the next incomplete required step.
    /// Handles edge cases: saved step beyond valid range, all steps already complete.
    private func resumeFromLastStep() {
        guard !hasResumed else { return }
        hasResumed = true

        let savedRawValue = settingsStore.onboardingLastStep

        // Edge case: saved step is 0 (welcome) or negative — start from the beginning
        guard savedRawValue > 0 else { return }

        // Edge case: saved step beyond valid range — clamp to last valid step
        let maxRaw = OnboardingStep.allCases.last?.rawValue ?? 0
        let clampedRaw = min(savedRawValue, maxRaw)
        guard let savedStep = OnboardingStep(rawValue: clampedRaw) else { return }

        // Find the first incomplete required step starting from the saved step.
        // If the saved step is already complete (e.g., permission granted between launches),
        // advance to the next step that still needs attention.
        let resumeStep = firstIncompleteStep(from: savedStep)
        currentStep = resumeStep
    }

    /// Returns the first step (starting from `start`) whose requirements are not yet satisfied.
    /// If all remaining steps are complete, returns `.completion`.
    private func firstIncompleteStep(from start: OnboardingStep) -> OnboardingStep {
        var step = start
        while step != .completion {
            if !isStepAlreadyComplete(step) {
                return step
            }
            guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { break }
            step = next
        }
        return .completion
    }

    /// Checks whether a step's requirements are already satisfied (used during resume).
    ///
    /// This differs from `isCurrentStepComplete` because it checks the underlying
    /// permission/model state rather than local UI state (e.g., `downloadComplete`).
    private func isStepAlreadyComplete(_ step: OnboardingStep) -> Bool {
        switch step {
        case .welcome:
            return true
        case .microphonePermission:
            return permissionManager.microphoneStatus == .authorized
        case .accessibilityPermission:
            return permissionManager.accessibilityStatus == .authorized
        case .modelSelection:
            // If the active model is already downloaded, this step is complete
            return settingsStore.activeModelName.isEmpty == false
                && availableModels.isEmpty == false
                && availableModels.contains(where: {
                    $0.id == settingsStore.activeModelName
                    && ($0.status == .downloaded || $0.status == .active)
                })
        case .testDictation:
            // Skippable — never blocks resume
            return true
        case .completion:
            return true
        }
    }

    // MARK: - Helpers

    private func dotColor(for step: OnboardingStep) -> Color {
        if step.rawValue < currentStep.rawValue {
            return theme.successColor
        } else if step == currentStep {
            return theme.accentColor
        } else {
            return theme.borderColor
        }
    }

    /// Direction of step transitions for animation context.
    enum TransitionDirection {
        case forward
        case backward
    }
}
