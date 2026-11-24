//
//  OnboardingModelSelectionStep.swift
//  wispr
//
//  Auto-downloads NVIDIA Parakeet V3 during onboarding.
//  Reuses ModelDownloadProgressView for download lifecycle.
//

import WisprCore
import SwiftUI

/// Model download step that automatically fetches and activates Parakeet V3.
struct OnboardingModelSelectionStep: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @Environment(StateManager.self) private var stateManager: StateManager

    /// The transcription engine used for model operations.
    let whisperService: any TranscriptionEngine

    // MARK: - Bindings to parent state

    @Binding var downloadComplete: Bool

    // MARK: - Local State

    /// The resolved Parakeet V3 model info, set by the `.task` block.
    @State private var parakeetModel: ModelInfo?

    /// Error message shown if model lookup fails.
    @State private var errorMessage: String?

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            OnboardingIconBadge(
                systemName: theme.actionSymbol(.model),
                color: downloadComplete ? theme.successColor : theme.accentColor
            )

            Text(downloadComplete ? "Model Ready" : "Downloading Model")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text(downloadComplete
                ? "NVIDIA Parakeet V3 is ready to use. You can switch to a different model anytime in Model Management."
                : "We're downloading NVIDIA Parakeet V3, a fast and accurate speech recognition model. You can switch to a different model anytime in Model Management.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .lineSpacing(5)

            if let errorMessage {
                errorView(message: errorMessage)
            } else if let parakeetModel {
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: parakeetModel,
                    autoStart: true,
                    onComplete: { completedModelId in
                        stateManager.markModelActive(completedModelId)
                        downloadComplete = true
                    },
                    onCancel: nil
                )
                .frame(maxWidth: 400)
            } else if downloadComplete {
                // Model was already downloaded before this view appeared;
                // no ModelDownloadProgressView needed.
                alreadyReadyView
            } else {
                ProgressView()
                    .controlSize(.regular)
                    .accessibilityLabel("Loading model information")
            }
        }
        .animation(theme.reduceMotion ? nil : .easeInOut(duration: 0.35), value: downloadComplete)
        .task {
            await resolveParakeetModel()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model Download step")
    }

    // MARK: - Already Ready (model was downloaded before onboarding)

    /// Shown only when `resolveParakeetModel` finds the model already downloaded/active,
    /// so no `ModelDownloadProgressView` was ever created.
    private var alreadyReadyView: some View {
        HStack(spacing: 10) {
            Image(systemName: SFSymbols.checkmarkPlain)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(theme.successColor.gradient, in: Circle())
            Text("Parakeet V3 ready")
                .font(.headline)
                .foregroundStyle(theme.successColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Parakeet V3 downloaded and ready")
    }

    // MARK: - Error

    private func errorView(message: String) -> some View {
        VStack(spacing: 10) {
            Label("Setup Failed", systemImage: SFSymbols.warning)
                .font(.headline)
                .foregroundStyle(theme.errorColor)

            Text(message)
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                errorMessage = nil
                Task { await resolveParakeetModel() }
            } label: {
                Label("Retry", systemImage: SFSymbols.retry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Retry model setup")
        }
    }

    // MARK: - Model Resolution

    /// Asks `StateManager` to get Parakeet V3 ready and shows the outcome.
    private func resolveParakeetModel() async {
        switch await stateManager.resolveOnboardingModel() {
        case .ready:
            downloadComplete = true
        case .needsDownload(let model):
            // Shows ModelDownloadProgressView, which starts the download.
            parakeetModel = model
        case .failed(let message):
            errorMessage = message
        }
    }
}
