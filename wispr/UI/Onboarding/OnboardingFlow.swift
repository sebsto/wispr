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

    /// Optional initial step override, used by previews to jump directly to a step.
    var initialStep: OnboardingStep = .welcome

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
                .padding(24)
        }
//        .frame(width: 620, height: 580)
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
                .font(.callout)
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

    /// Content area for the current step, wrapped in a ScrollView so taller
    /// steps (e.g. model selection with 5 rows) don't push the step indicator
    /// or navigation bar off-screen.
    private var stepContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                switch currentStep {
                case .welcome:
                    OnboardingWelcomeStep()
                case .microphonePermission:
                    OnboardingMicPermissionStep()
                case .accessibilityPermission:
                    OnboardingAccessibilityStep()
                case .modelSelection:
                    OnboardingModelSelectionStep(
                        whisperService: whisperService,
                        availableModels: $availableModels,
                        selectedModelId: $selectedModelId,
                        downloadComplete: $downloadComplete
                    )
                case .testDictation:
                    OnboardingTestDictationStep(
                        testTranscriptionResult: $testTranscriptionResult,
                        isTestRecording: $isTestRecording,
                        isTestProcessing: $isTestProcessing,
                        currentStep: currentStep
                    )
                case .completion:
                    OnboardingCompletionStep()
                }
            }
            .padding(32)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - Placeholder Step Content

    func placeholderStepContent(icon: String, title: String, description: String) -> some View {
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
                .accessibilityLabel("Done")
                .accessibilityHint("Completes setup and closes the onboarding window")
            } else if currentStep.isSkippable && !isCurrentStepComplete {
                HStack(spacing: 12) {
                    Button("Skip") {
                        goForward()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondaryTextColor)
                    .accessibilityLabel("Skip this step")
                    .accessibilityHint("Skips the test dictation step")

                    Button("Continue") {
                        goForward()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
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

        // If an explicit initial step was provided (e.g. previews), jump directly.
        if initialStep != .welcome {
            currentStep = initialStep
            return
        }

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
