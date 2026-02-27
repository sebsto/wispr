//
//  ModelManagementView.swift
//  wispr
//
//  SwiftUI List-based view for managing Whisper models.
//  Requirements: 7.2, 7.3, 7.4, 7.6, 7.7, 7.8, 7.9, 7.10, 14.3, 14.12
//

import SwiftUI

/// View displaying all available Whisper models with download, delete, and activation controls.
///
/// Requirement 7.2: List all available models with name, size, and status.
/// Requirement 7.3: Show download status (not downloaded, downloading %, downloaded, active).
/// Requirement 14.3: Apply Liquid Glass materials.
/// Requirement 14.12: Liquid Glass translucency on window background.
struct ModelManagementView: View {
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// The WhisperService actor used for model operations.
    private let whisperService: WhisperService

    /// Local state: snapshot of models with their current statuses.
    @State private var models: [WhisperModelInfo] = []

    /// Tracks download progress per model ID.
    @State private var downloadProgresses: [String: Double] = [:]

    /// Model pending deletion confirmation.
    @State private var modelToDelete: WhisperModelInfo?

    /// Whether the delete confirmation dialog is shown.
    @State private var showDeleteConfirmation = false

    /// Whether a "no models" alert is shown after deleting the last model.
    @State private var showNoModelsAlert = false

    /// Error message to display.
    @State private var errorMessage: String?

    init(whisperService: WhisperService) {
        self.whisperService = whisperService
    }

    var body: some View {
        List {
            ForEach(models) { model in
                ModelRowView(
                    model: model,
                    downloadProgress: downloadProgresses[model.id],
                    theme: theme,
                    onDownload: { await downloadModel(model) },
                    onSetActive: { await setActiveModel(model) },
                    onDelete: { requestDelete(model) }
                )
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .liquidGlassPanel()
        .navigationTitle("Model Management")
        .task {
            await refreshModels()
        }
        .confirmationDialog(
            "Delete Model",
            isPresented: $showDeleteConfirmation,
            presenting: modelToDelete
        ) { model in
            Button("Delete \(model.displayName)", role: .destructive) {
                Task { await performDelete(model) }
            }
            Button("Cancel", role: .cancel) {
                modelToDelete = nil
            }
        } message: { model in
            Text("Are you sure you want to delete the \(model.displayName) model (\(model.sizeDescription))? This cannot be undone.")
        }
        .alert("No Models Available", isPresented: $showNoModelsAlert) {
            Button("OK") {}
        } message: {
            Text("All models have been removed. Please download a model to continue using Wisp.")
        }
        .alert("Error", isPresented: .init(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Actions

    /// Refreshes the model list with current statuses from WhisperService.
    private func refreshModels() async {
        var allModels = await whisperService.availableModels()
        for index in allModels.indices {
            allModels[index].status = await whisperService.modelStatus(allModels[index].id)
        }
        models = allModels
    }

    /// Downloads a model and tracks progress.
    ///
    /// Requirement 7.2: Download model with real-time progress.
    /// Requirement 7.4: Display percentage and bytes transferred.
    private func downloadModel(_ model: WhisperModelInfo) async {
        downloadProgresses[model.id] = 0.0
        updateModelStatus(model.id, to: .downloading(progress: 0.0))

        let stream = await whisperService.downloadModel(model)

        do {
            for try await progress in stream {
                downloadProgresses[model.id] = progress.fractionCompleted
                updateModelStatus(model.id, to: .downloading(progress: progress.fractionCompleted))
            }
            // Download completed successfully
            downloadProgresses.removeValue(forKey: model.id)
            await refreshModels()
        } catch {
            downloadProgresses.removeValue(forKey: model.id)
            errorMessage = "Download failed: \(error.localizedDescription)"
            await refreshModels()
        }
    }

    /// Sets a downloaded model as the active model.
    ///
    /// Requirement 7.6: Switch active model.
    /// Requirement 7.7: Allow changing active model when not recording.
    private func setActiveModel(_ model: WhisperModelInfo) async {
        do {
            try await whisperService.switchModel(to: model.id)
            settingsStore.activeModelName = model.id
            await refreshModels()
        } catch {
            errorMessage = "Failed to activate model: \(error.localizedDescription)"
        }
    }

    /// Shows the delete confirmation dialog.
    private func requestDelete(_ model: WhisperModelInfo) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    /// Performs model deletion with fallback logic.
    ///
    /// Requirement 7.8: Remove model files from disk.
    /// Requirement 7.9: Switch to next smallest model before deleting active model.
    /// Requirement 7.10: Prompt to download if deleting the only model.
    private func performDelete(_ model: WhisperModelInfo) async {
        do {
            try await whisperService.deleteModel(model.id)

            // Check if the deleted model was the active one in settings
            if settingsStore.activeModelName == model.id {
                // Update settings to reflect the new active model (if any)
                if let newActive = await whisperService.activeModel() {
                    settingsStore.activeModelName = newActive
                }
            }

            await refreshModels()

            // Requirement 7.10: Check if no models remain downloaded
            let hasDownloaded = models.contains { status in
                if case .downloaded = status.status { return true }
                if case .active = status.status { return true }
                return false
            }
            if !hasDownloaded {
                showNoModelsAlert = true
            }
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
        }

        modelToDelete = nil
    }

    /// Updates a model's status in the local state array.
    private func updateModelStatus(_ modelId: String, to status: ModelStatus) {
        if let index = models.firstIndex(where: { $0.id == modelId }) {
            models[index].status = status
        }
    }
}

// MARK: - ModelRowView

/// A single row in the model list showing model info and action controls.
private struct ModelRowView: View {
    let model: WhisperModelInfo
    let downloadProgress: Double?
    let theme: UIThemeEngine
    let onDownload: () async -> Void
    let onSetActive: () async -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            modelInfoSection
            Spacer()
            statusSection
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Model Info

    private var modelInfoSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(model.displayName)
                    .font(.headline)
                    .foregroundStyle(theme.primaryTextColor)

                if case .active = model.status {
                    Image(systemName: theme.actionSymbol(.checkmark))
                        .foregroundStyle(theme.successColor)
                        .font(.subheadline)
                        .accessibilityLabel("Active model")
                }
            }

            Text(model.sizeDescription)
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)

            Text(model.qualityDescription)
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)
        }
    }

    // MARK: - Status & Actions

    @ViewBuilder
    private var statusSection: some View {
        switch model.status {
        case .notDownloaded:
            downloadButton

        case .downloading:
            downloadingIndicator

        case .downloaded:
            downloadedActions

        case .active:
            activeActions
        }
    }

    /// Download button for models that haven't been downloaded yet.
    /// Requirement 7.2: Initiate model download.
    private var downloadButton: some View {
        Button {
            Task { await onDownload() }
        } label: {
            Label("Download", systemImage: theme.actionSymbol(.download))
        }
        .buttonStyle(.bordered)
        .highContrastBorder(cornerRadius: 6)
        .minimumTouchTarget()
        .keyboardFocusRing()
        .accessibilityLabel("Download \(model.displayName) model")
        .accessibilityHint("Downloads the \(model.sizeDescription) model")
    }

    /// Progress indicator shown while a model is downloading.
    /// Requirement 7.3: Show download progress with percentage.
    private var downloadingIndicator: some View {
        VStack(spacing: 4) {
            let progress = downloadProgress ?? 0.0
            ProgressView(value: progress)
                .frame(width: 100)
                .accessibilityLabel("Downloading \(model.displayName)")
                .accessibilityValue("\(Int(progress * 100)) percent")

            Text("\(Int(progress * 100))%")
                .font(.caption2)
                .foregroundStyle(theme.secondaryTextColor)
        }
    }

    /// Action buttons for downloaded (non-active) models.
    /// Requirement 7.6: Set active button.
    /// Requirement 7.8: Delete button.
    private var downloadedActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await onSetActive() }
            } label: {
                Text("Set Active")
            }
            .buttonStyle(.bordered)
            .highContrastBorder(cornerRadius: 6)
            .minimumTouchTarget()
            .keyboardFocusRing()
            .accessibilityLabel("Set \(model.displayName) as active model")
            .accessibilityHint("Switches transcription to use this model")

            Button(role: .destructive) {
                onDelete()
            } label: {
                Image(systemName: theme.actionSymbol(.delete))
            }
            .buttonStyle(.bordered)
            .highContrastBorder(cornerRadius: 6)
            .minimumTouchTarget()
            .keyboardFocusRing()
            .accessibilityLabel("Delete \(model.displayName) model")
            .accessibilityHint("Removes the model from disk")
        }
    }

    /// Action buttons for the currently active model.
    private var activeActions: some View {
        Button(role: .destructive) {
            onDelete()
        } label: {
            Image(systemName: theme.actionSymbol(.delete))
        }
        .buttonStyle(.bordered)
        .highContrastBorder(cornerRadius: 6)
        .minimumTouchTarget()
        .keyboardFocusRing()
        .accessibilityLabel("Delete \(model.displayName) model")
        .accessibilityHint("Removes the active model from disk. A different model will be activated.")
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = [model.displayName, model.sizeDescription, model.qualityDescription]
        switch model.status {
        case .notDownloaded:
            parts.append("Not downloaded")
        case .downloading(let progress):
            parts.append("Downloading \(Int(progress * 100)) percent")
        case .downloaded:
            parts.append("Downloaded")
        case .active:
            parts.append("Active")
        }
        return parts.joined(separator: ", ")
    }
}
