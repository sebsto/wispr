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

    /// Whether an already-downloaded model is being loaded and warmed up.
    @State private var isPreparingModel = false

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
                // Self-contained download progress view
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: selectedModel,
                    autoStart: true,
                    onComplete: { completedModelId in
                        settingsStore.activeModelName = completedModelId
                        downloadComplete = true
                        isShowingDownload = false

                        // Update model statuses so the row icons/labels refresh
                        for index in availableModels.indices {
                            if availableModels[index].id == completedModelId {
                                availableModels[index].status = .active
                            } else if availableModels[index].status == .active {
                                availableModels[index].status = .downloaded
                            }
                        }
                    },
                    onCancel: {
                        isShowingDownload = false
                    }
                )
                .frame(maxWidth: 400)
            } else {
                // Model list for selection
                modelListView

                if isPreparingModel {
                    preparingModelIndicator
                }
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
        }
    }

    /// Spinner shown while an already-downloaded model is being loaded and warmed up.
    private var preparingModelIndicator: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Preparing model…")
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)
        }
        .padding(.top, 4)
    }

    /// A single row showing model info, a status icon, and an inline action button.
    private func modelRow(_ model: WhisperModelInfo) -> some View {
        let isSelected = selectedModelId == model.id
        let isOnDisk = model.status == .downloaded || model.status == .active

        return Button {
            selectedModelId = model.id
            if isOnDisk {
                downloadComplete = false
                isPreparingModel = true
                Task {
                    if await whisperService.activeModel() != model.id {
                        do {
                            try await whisperService.loadModel(model.id)
                        } catch {
                            isPreparingModel = false
                            return
                        }
                    }
                    settingsStore.activeModelName = model.id
                    downloadComplete = true
                    isPreparingModel = false
                }
            } else {
                downloadComplete = false
            }
        } label: {
            HStack(spacing: 10) {
                // Status icon
                modelStatusIcon(for: model)

                // Model info
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundStyle(isOnDisk ? theme.primaryTextColor : theme.secondaryTextColor)

                    Text("\(model.sizeDescription) · \(model.qualityDescription)")
                        .font(.caption)
                        .foregroundStyle(theme.secondaryTextColor)
                }

                Spacer()

                // Trailing action / status
                if isSelected && !isOnDisk {
                    Button {
                        isShowingDownload = true
                    } label: {
                        Label("Download", systemImage: theme.actionSymbol(.download))
                            .font(.callout.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Download \(model.displayName)")
                } else if isOnDisk {
                    statusPill(
                        label: model.status == .active ? "Active" : "Downloaded",
                        color: model.status == .active ? theme.successColor : theme.accentColor
                    )
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isSelected ? theme.accentColor.opacity(0.1) : Color.primary.opacity(0.03))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? theme.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
            .highContrastBorder(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(modelAccessibilityLabel(model, isOnDisk: isOnDisk))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityHint(isOnDisk ? "Select this downloaded model" : "Select this model, then download")
    }

    // MARK: - Row Subviews

    /// Leading status icon matching the ModelManagement style.
    @ScaledMetric(relativeTo: .body) private var statusIconSize: CGFloat = 28

    private func modelStatusIcon(for model: WhisperModelInfo) -> some View {
        Group {
            switch model.status {
            case .active:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: statusIconSize, height: statusIconSize)
                    .background(theme.successColor.gradient, in: Circle())

            case .downloaded:
                Image(systemName: "arrow.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: statusIconSize, height: statusIconSize)
                    .background(theme.accentColor.gradient, in: Circle())

            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    .frame(width: statusIconSize, height: statusIconSize)
                    .background(theme.secondaryTextColor.opacity(0.08), in: Circle())

            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: statusIconSize, height: statusIconSize)
            }
        }
        .accessibilityHidden(true)
    }

    /// A small pill showing status text.
    private func statusPill(label: String, color: Color) -> some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.medium)
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.12)))
    }

    private func modelAccessibilityLabel(_ model: WhisperModelInfo, isOnDisk: Bool) -> String {
        var parts = [model.displayName, model.sizeDescription, model.qualityDescription]
        if isOnDisk {
            parts.append(model.status == .active ? "Active" : "Downloaded")
        } else {
            parts.append("Not downloaded")
        }
        return parts.joined(separator: ", ")
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
