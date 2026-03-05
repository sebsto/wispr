//
//  OnboardingModelSelectionStep.swift
//  wispr
//
//  Model selection step for the onboarding flow.
//  Reuses ModelRowView from ModelManagementView for visual consistency.
//  Requirements: 13.6, 13.7, 13.8, 13.15
//

import SwiftUI

/// Model selection step with model list, download progress, and error handling.
struct OnboardingModelSelectionStep: View {
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// The WhisperService actor used for model operations.
    let whisperService: WhisperService

    // MARK: - Bindings to parent state

    @Binding var availableModels: [WhisperModelInfo]
    @Binding var selectedModelId: String?
    @Binding var downloadComplete: Bool

    // MARK: - Local State

    /// Whether the download progress view is currently shown.
    @State private var isShowingDownload = false

    /// The model ID currently being activated (loading into memory).
    @State private var activatingModelId: String?

    /// Tracks which model ID shows the green highlight overlay.
    @State private var highlightedModelId: String?

    /// Namespace for matchedGeometryEffect on the active highlight.
    @Namespace private var highlightNamespace

    // MARK: - Body

    var body: some View {
        VStack(spacing: 20) {
            OnboardingIconBadge(
                systemName: theme.actionSymbol(.model),
                color: downloadComplete ? theme.successColor : theme.accentColor
            )

            Text("Choose a Model")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Select a Whisper model to download. Smaller models are faster; larger models are more accurate.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .lineSpacing(5)

            if isShowingDownload,
               let modelId = selectedModelId,
               let selectedModel = availableModels.first(where: { $0.id == modelId }) {
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: selectedModel,
                    autoStart: true,
                    onComplete: { completedModelId in
                        settingsStore.activeModelName = completedModelId
                        downloadComplete = true
                        isShowingDownload = false
                        updateModelStatuses(activeId: completedModelId)
                        highlightedModelId = completedModelId
                    },
                    onCancel: {
                        isShowingDownload = false
                    }
                )
                .frame(maxWidth: 400)
            } else {
                // Model list using shared ModelRowView for consistency
                modelListView
            }
        }
        .animation(theme.reduceMotion ? nil : .easeInOut(duration: 0.35), value: highlightedModelId)
        .task {
            await loadAvailableModels()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Model Selection step")
    }

    // MARK: - Model List

    private var modelListView: some View {
        VStack(spacing: 0) {
            ForEach(availableModels) { model in
                ModelRowView(
                    model: model,
                    theme: theme,
                    isActivating: activatingModelId == model.id,
                    isHighlighted: highlightedModelId == model.id,
                    namespace: highlightNamespace,
                    onDownload: {
                        selectedModelId = model.id
                        isShowingDownload = true
                    },
                    onSetActive: {
                        await activateModel(model)
                    },
                    onDelete: {
                        // No delete during onboarding
                    }
                )
                if model.id != availableModels.last?.id {
                    Divider()
                }
            }
        }
    }

    // MARK: - Actions

    /// Activates an already-downloaded model.
    private func activateModel(_ model: WhisperModelInfo) async {
        selectedModelId = model.id
        downloadComplete = false

        // Animate highlight to the new model
        if !theme.reduceMotion {
            withAnimation(.easeInOut(duration: 0.35)) {
                highlightedModelId = model.id
            }
            try? await Task.sleep(for: .milliseconds(400))
        } else {
            highlightedModelId = model.id
        }

        activatingModelId = model.id
        do {
            if await whisperService.activeModel() != model.id {
                try await whisperService.loadModel(model.id)
            }
            settingsStore.activeModelName = model.id
            updateModelStatuses(activeId: model.id)
            downloadComplete = true
        } catch {
            // Revert highlight on failure
            let activeId = availableModels.first(where: {
                if case .active = $0.status { return true }
                return false
            })?.id
            highlightedModelId = activeId
        }
        activatingModelId = nil
    }

    /// Updates model statuses so only the given ID is `.active`.
    private func updateModelStatuses(activeId: String) {
        for index in availableModels.indices {
            if availableModels[index].id == activeId {
                availableModels[index].status = .active
            } else if availableModels[index].status == .active {
                availableModels[index].status = .downloaded
            }
        }
    }

    // MARK: - Model Loading

    /// Loads the available models from WhisperService, querying actual disk status for each.
    func loadAvailableModels() async {
        var models = await whisperService.availableModels()
        for index in models.indices {
            models[index].status = await whisperService.modelStatus(models[index].id)
        }
        availableModels = models

        // Set initial highlight to the active model
        let activeId = models.first(where: {
            if case .active = $0.status { return true }
            return false
        })?.id
        highlightedModelId = activeId

        // If a model matching the active setting is already active in WhisperKit,
        // just mark the step complete — no need to reload.
        if !settingsStore.activeModelName.isEmpty {
            let currentActive = await whisperService.activeModel()
            if currentActive == settingsStore.activeModelName {
                downloadComplete = true
            }
        }

        // Pre-select the active model, or the first model if nothing is selected
        if selectedModelId == nil {
            if !settingsStore.activeModelName.isEmpty,
               models.contains(where: { $0.id == settingsStore.activeModelName }) {
                selectedModelId = settingsStore.activeModelName
            } else if let first = models.first {
                selectedModelId = first.id
            }
        }
    }
}
