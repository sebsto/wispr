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

    /// The model ID currently being activated (loading into memory).
    @State private var activatingModelId: String?

    /// Tracks which model ID currently shows the green highlight overlay.
    /// Drives the animated transition when switching active models.
    @State private var highlightedModelId: String?

    /// Namespace used by `matchedGeometryEffect` so the green highlight
    /// slides from one row to another instead of fading independently.
    @Namespace private var highlightNamespace

    init(whisperService: WhisperService) {
        self.whisperService = whisperService
    }

    var body: some View {
        List {
            ForEach(models) { model in
                modelSection(for: model)
            }
        }
        .animation(theme.reduceMotion ? nil : .easeInOut(duration: 0.35), value: highlightedModelId)
        .frame(minWidth: 500, idealWidth: 540)
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
                isActivating: activatingModelId == model.id,
                isHighlighted: highlightedModelId == model.id,
                namespace: highlightNamespace,
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

        // Keep highlightedModelId in sync with the actual active model.
        let activeId = allModels.first(where: {
            if case .active = $0.status { return true }
            return false
        })?.id
        if highlightedModelId != activeId {
            highlightedModelId = activeId
        }
    }

    /// Sets a downloaded model as the active model.
    ///
    /// Requirement 7.6: Switch active model.
    /// Requirement 7.7: Allow changing active model when not recording.
    private func setActiveModel(_ model: WhisperModelInfo) async {
        // Animate the green highlight to the new model before starting activation.
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
            try await whisperService.switchModel(to: model.id)
            settingsStore.activeModelName = model.id
            activatingModelId = nil
            await refreshModels()
        } catch {
            activatingModelId = nil
            // Revert highlight back to the actual active model on failure.
            let activeId = models.first(where: {
                if case .active = $0.status { return true }
                return false
            })?.id
            highlightedModelId = activeId
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
/// Status is displayed as a prominent badge/pill for at-a-glance clarity.
/// The active model uses a highlighted card with a green border.
private struct ModelRowView: View {
    let model: WhisperModelInfo
    let theme: UIThemeEngine
    let isActivating: Bool
    let isHighlighted: Bool
    let namespace: Namespace.ID
    let onDownload: () -> Void
    let onSetActive: () async -> Void
    let onDelete: () -> Void

    /// Whether this model is the active one.
    private var isActive: Bool {
        if case .active = model.status { return true }
        return false
    }

    /// Whether this model has not been downloaded.
    private var isNotDownloaded: Bool {
        if case .notDownloaded = model.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: status icon, model name + info, status badge
            HStack(alignment: .center, spacing: 10) {
                statusIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundStyle(isNotDownloaded
                            ? theme.secondaryTextColor
                            : theme.primaryTextColor)

                    HStack(spacing: 6) {
                        Text(model.sizeDescription)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryTextColor)

                        Text("·")
                            .foregroundStyle(theme.secondaryTextColor)

                        Text(model.qualityDescription)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                }

                Spacer()

                statusBadge
            }

            // Bottom row: action buttons aligned trailing
            actionButtons
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 10)
                    .fill(theme.successColor.opacity(0.06))
                    .matchedGeometryEffect(id: "activeHighlight", in: namespace)
            }
        }
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(theme.successColor.opacity(0.5), lineWidth: 1.5)
                    .matchedGeometryEffect(id: "activeHighlightBorder", in: namespace)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
        .opacity(isActivating ? 0.7 : 1.0)
        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isActivating)
    }

    // MARK: - Status Icon

    /// A leading icon that reflects the model's current state.
    private var statusIcon: some View {
        Group {
            switch model.status {
            case .active:
                Image(systemName: theme.actionSymbol(.checkmark))
                    .foregroundStyle(theme.successColor)
                    .font(.title2)

            case .downloaded:
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(theme.accentColor)
                    .font(.title2)

            case .notDownloaded:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    .font(.title2)

            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 22, height: 22)
            }
        }
        .frame(width: 28, alignment: .center)
    }

    // MARK: - Status Badge

    /// A prominent pill-shaped badge showing the model's status.
    private var statusBadge: some View {
        Group {
            switch model.status {
            case .active:
                StatusPillView(
                    label: "Active",
                    symbolName: theme.actionSymbol(.checkmark),
                    foregroundColor: theme.successColor,
                    backgroundColor: theme.successColor.opacity(0.15)
                )

            case .downloaded:
                StatusPillView(
                    label: "Downloaded",
                    symbolName: "checkmark.circle",
                    foregroundColor: theme.accentColor,
                    backgroundColor: theme.accentColor.opacity(0.12)
                )

            case .notDownloaded:
                StatusPillView(
                    label: "Not Downloaded",
                    symbolName: "icloud.and.arrow.down",
                    foregroundColor: theme.secondaryTextColor,
                    backgroundColor: theme.borderColor.opacity(0.3)
                )

            case .downloading:
                StatusPillView(
                    label: "Downloading…",
                    symbolName: nil,
                    foregroundColor: theme.accentColor,
                    backgroundColor: theme.accentColor.opacity(0.12)
                )
            }
        }
    }

    // MARK: - Action Buttons

    /// Action buttons appropriate for the model's current status.
    @ViewBuilder
    private var actionButtons: some View {
        switch model.status {
        case .notDownloaded:
            HStack {
                Spacer()
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

        case .downloading:
            // Handled by the parent via ModelDownloadProgressView
            EmptyView()

        case .downloaded:
            HStack {
                Spacer()
                if isActivating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Activating…")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryTextColor)
                } else {
                    Button {
                        Task { await onSetActive() }
                    } label: {
                        Label("Activate", systemImage: theme.actionSymbol(.checkmark))
                    }
                    .buttonStyle(.borderedProminent)
                    .highContrastBorder(cornerRadius: 6)
                    .keyboardFocusRing()
                    .accessibilityLabel("Set \(model.displayName) as active model")
                    .accessibilityHint("Switches transcription to use this model")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: theme.actionSymbol(.delete))
                }
                .buttonStyle(.bordered)
                .highContrastBorder(cornerRadius: 6)
                .keyboardFocusRing()
                .disabled(isActivating)
                .accessibilityLabel("Delete \(model.displayName) model")
                .accessibilityHint("Removes the model from disk")
            }

        case .active:
            HStack {
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: theme.actionSymbol(.delete))
                }
                .buttonStyle(.bordered)
                .highContrastBorder(cornerRadius: 6)
                .keyboardFocusRing()
                .accessibilityLabel("Delete \(model.displayName) model")
                .accessibilityHint("Removes the active model from disk. A different model will be activated.")
            }
        }
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

// MARK: - StatusPillView

/// A reusable pill-shaped badge for displaying model status at a glance.
private struct StatusPillView: View {
    let label: String
    let symbolName: String?
    let foregroundColor: Color
    let backgroundColor: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.caption2.weight(.semibold))
            }
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .overlay(
            Capsule()
                .strokeBorder(foregroundColor.opacity(0.3), lineWidth: 0.5)
        )
    }
}

#if DEBUG

/// Wrapper that owns the `@Namespace` required by `ModelRowView` previews.
private struct ModelRowPreviewWrapper: View {
    @Namespace private var namespace
    let theme: UIThemeEngine
    let models: [WhisperModelInfo]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(models) { model in
                    ModelRowView(
                        model: model,
                        theme: theme,
                        isActivating: false,
                        isHighlighted: {
                            if case .active = model.status { return true }
                            return false
                        }(),
                        namespace: namespace,
                        onDownload: {},
                        onSetActive: {},
                        onDelete: {}
                    )
                    Divider()
                }
            }
            .padding()
        }
    }
}

#Preview("Model Management") {
    let theme = PreviewMocks.makeTheme()
    let settingsStore = PreviewMocks.makeSettingsStore()
    let models: [WhisperModelInfo] = [
        WhisperModelInfo(id: "tiny", displayName: "Tiny", sizeDescription: "~75 MB",
                         qualityDescription: "Fastest, lower accuracy", status: .active),
        WhisperModelInfo(id: "base", displayName: "Base", sizeDescription: "~140 MB",
                         qualityDescription: "Fast, moderate accuracy", status: .downloaded),
        WhisperModelInfo(id: "small", displayName: "Small", sizeDescription: "~460 MB",
                         qualityDescription: "Balanced speed and accuracy", status: .notDownloaded),
        WhisperModelInfo(id: "large-v3", displayName: "Large v3", sizeDescription: "~3 GB",
                         qualityDescription: "Slowest, highest accuracy", status: .notDownloaded),
    ]
    ModelRowPreviewWrapper(theme: theme, models: models)
        .environment(settingsStore)
        .environment(theme)
}
#endif
