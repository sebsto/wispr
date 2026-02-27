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
    @Binding var downloadProgress: Double
    @Binding var downloadTotalBytes: Int64
    @Binding var downloadedBytes: Int64
    @Binding var isDownloading: Bool
    @Binding var downloadError: String?
    @Binding var downloadComplete: Bool

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

    // MARK: - Model List

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

    // MARK: - Download Progress

    /// Real-time download progress display (Req 13.7).
    private var modelDownloadProgressView: some View {
        VStack(spacing: 12) {
            ProgressView(value: downloadProgress)
                .progressViewStyle(.linear)
                .frame(maxWidth: 360)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(downloadProgress * 100)) percent")

            Text("\(Int(downloadProgress * 100))% — \(formattedBytes(downloadedBytes)) of \(formattedBytes(downloadTotalBytes))")
                .font(.callout)
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
                .font(.callout)
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
            .accessibilityLabel("Retry download")
            .accessibilityHint("Attempts to download the model again")
        }
    }

    // MARK: - Model Download Logic

    /// Loads the available models from WhisperService, querying actual disk status for each.
    func loadAvailableModels() async {
        var models = await whisperService.availableModels()
        for index in models.indices {
            models[index].status = await whisperService.modelStatus(models[index].id)
        }
        availableModels = models

        // If a model matching the active setting is already downloaded, mark step complete
        if !settingsStore.activeModelName.isEmpty,
           models.contains(where: {
               $0.id == settingsStore.activeModelName
               && ($0.status == .downloaded || $0.status == .active)
           }) {
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

    /// Starts downloading the selected model and tracks progress.
    func startModelDownload() {
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
}
