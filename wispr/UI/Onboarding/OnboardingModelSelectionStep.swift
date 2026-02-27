//
//  OnboardingModelSelectionStep.swift
//  wispr
//
//  Model selection step for the onboarding flow.
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

    // MARK: - Body

    var body: some View {
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
                .lineSpacing(4)

            if downloadComplete || isShowingDownload,
               let modelId = selectedModelId,
               let selectedModel = availableModels.first(where: { $0.id == modelId }) {
                // Self-contained download progress view
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: selectedModel,
                    autoStart: true,
                    onComplete: { completedModelId in
                        settingsStore.activeModelName = completedModelId
                        downloadComplete = true
                        isShowingDownload = false
                    },
                    onCancel: {
                        isShowingDownload = false
                    }
                )
                .frame(maxWidth: 400)
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

    // MARK: - Model List

    /// List of available models for the user to pick from.
    private var modelListView: some View {
        VStack(spacing: 8) {
            ForEach(availableModels) { model in
                modelRow(model)
            }

            if selectedModelId != nil {
                Button {
                    isShowingDownload = true
                } label: {
                    Label("Download", systemImage: theme.actionSymbol(.download))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
                .accessibilityLabel("Download selected model")
                .accessibilityHint("Downloads the selected Whisper model to your Mac")
            }
        }
    }

    /// A single row in the model list.
    private func modelRow(_ model: WhisperModelInfo) -> some View {
        let isSelected = selectedModelId == model.id
        let isOnDisk = model.status == .downloaded || model.status == .active
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundStyle(theme.primaryTextColor)
                    if isOnDisk {
                        Text("Downloaded")
                            .font(.caption2)
                            .foregroundStyle(theme.successColor)
                    }
                }
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

    // MARK: - Model Download Logic

    /// Loads the available models from WhisperService, querying actual disk status for each.
    func loadAvailableModels() async {
        var models = await whisperService.availableModels()
        for index in models.indices {
            models[index].status = await whisperService.modelStatus(models[index].id)
        }
        availableModels = models

        // If a model matching the active setting is already downloaded, ensure it's
        // loaded into WhisperKit so test dictation works, then mark step complete.
        if !settingsStore.activeModelName.isEmpty,
           models.contains(where: {
               $0.id == settingsStore.activeModelName
               && ($0.status == .downloaded || $0.status == .active)
           }) {
            // Load the model BEFORE enabling Continue so WhisperKit is ready
            // when the user reaches the test dictation step.
            let modelName = settingsStore.activeModelName
            if await whisperService.activeModel() != modelName {
                try? await whisperService.loadModel(modelName)
            }
            downloadComplete = true
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
