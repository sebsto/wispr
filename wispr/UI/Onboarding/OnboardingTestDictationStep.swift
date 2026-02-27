//
//  OnboardingTestDictationStep.swift
//  wispr
//
//  Test dictation step for the onboarding flow.
//  Requirements: 13.9, 13.10
//

import SwiftUI

/// Test dictation step where the user can try the hotkey and see transcribed text.
///
/// Observes `StateManager.appState` to track recording/processing states and
/// captures the transcription result when the cycle completes.
struct OnboardingTestDictationStep: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @Environment(StateManager.self) private var stateManager: StateManager

    @Binding var testTranscriptionResult: String
    @Binding var isTestRecording: Bool
    @Binding var isTestProcessing: Bool

    /// The current onboarding step, used to guard state change handling.
    let currentStep: OnboardingStep

    var body: some View {
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
                .lineSpacing(4)

            // State-dependent content
            if isTestProcessing {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Processing speech")

                Text("Transcribing…")
                    .font(.callout)
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
                    .font(.callout)
                    .foregroundStyle(theme.secondaryTextColor)
            }
        }
        .onChange(of: stateManager.appState) { _, newState in
            handleTestDictationStateChange(newState)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Test Dictation step")
    }

    // MARK: - Helpers

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
            // If we were processing, the cycle completed successfully
            if isTestProcessing {
                if testTranscriptionResult.isEmpty {
                    testTranscriptionResult = "Dictation working! Your speech was transcribed successfully."
                }
            }
            isTestRecording = false
            isTestProcessing = false
        case .error(let message):
            isTestRecording = false
            isTestProcessing = false
            _ = message // Error is displayed by the overlay; user can retry
        }
    }
}
