//
//  ModelManagementView.swift
//  wispr
//
//  SwiftUI view for managing Whisper models with comprehensive download feedback.
//  Uses the shared ModelDownloadProgressView for consistent UX with onboarding.
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

    /// Model IDs currently showing the download progress view.
    @State private var activeDownloads: Set<String> = []

    /// Model pending deletion confirmation.
    @State private var modelToDelete: WhisperModelInfo?

    /// Whether the delete confirmation dialog is shown.
    @State private var showDeleteConfirmation = false

    /// Whether a "no models" alert is shown after deleting the last model.
    @State private var showNoModelsAlert = false

    /// Error message to display (for non-download errors).
    @State private var errorMessage: String?

    init(whisperService: WhisperService) {
        self.whisperService = whisperService
    }

    var body: some View {
        List {
            ForEach(models) { model in
                modelSection(for: model)
            }
        }
        .frame(minWidth: 500, idealWidth: 540, minHeight: 420, idealHeight: 480)
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

    // MARK: - Model Section

    /// Builds the view for a single model: either the inline download progress or the standard row.
    @ViewBuilder
    private func modelSection(for model: WhisperModelInfo) -> some View {
        if activeDownloads.contains(model.id) {
            // Self-contained download progress view
            ModelDownloadProgressView(
                whisperService: whisperService,
                model: model,
                autoStart: true,
                onComplete: { modelId in
                    settingsStore.activeModelName = modelId
                    activeDownloads.remove(modelId)
                    Task { await refreshModels() }
                },
                onCancel: {
                    activeDownloads.remove(model.id)
                    Task { await refreshModels() }
                }
            )
            .padding(.vertical, 8)
        } else {
            // Standard model row with info and action buttons
            ModelRowView(
                model: model,
                theme: theme,
                onDownload: {
                    activeDownloads.insert(model.id)
                    updateModelStatus(model.id, to: .downloading(progress: 0.0))
                },
                onSetActive: { await setActiveModel(model) },
                onDelete: { requestDelete(model) }
            )
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

            if settingsStore.activeModelName == model.id {
                if let newActive = await whisperService.activeModel() {
                    settingsStore.activeModelName = newActive
                }
            }

            await refreshModels()

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
    let theme: UIThemeEngine
    let onDownload: () -> Void
    let onSetActive: () async -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            modelInfoSection
            Spacer()
            statusSection
        }
        .padding(.vertical, 8)
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
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)

            Text(model.qualityDescription)
                .font(.caption)
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
            // Handled by the parent via ModelDownloadProgressView
            EmptyView()

        case .downloaded:
            downloadedActions

        case .active:
            activeActions
        }
    }

    /// Download button for models that haven't been downloaded yet.
    private var downloadButton: some View {
        Button {
            onDownload()
        } label: {
            Label("Download", systemImage: theme.actionSymbol(.download))
        }
        .buttonStyle(.bordered)
        .highContrastBorder(cornerRadius: 6)
        .keyboardFocusRing()
        .accessibilityLabel("Download \(model.displayName) model")
        .accessibilityHint("Downloads the \(model.sizeDescription) model")
    }

    /// Action buttons for downloaded (non-active) models.
    private var downloadedActions: some View {
        HStack(spacing: 8) {
            Button {
                Task { await onSetActive() }
            } label: {
                Text("Set Active")
            }
            .buttonStyle(.bordered)
            .highContrastBorder(cornerRadius: 6)
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

#if DEBUG
private struct ModelManagementPreview: View {
    @State private var settingsStore = PreviewMocks.makeSettingsStore()
    @State private var theme = PreviewMocks.makeTheme()

    var body: some View {
        ModelManagementView(whisperService: PreviewMocks.makeWhisperService())
            .environment(settingsStore)
            .environment(theme)
            .frame(width: 540, height: 480)
    }
}

#Preview("Model Management") {
    ModelManagementPreview()
}
#endif
