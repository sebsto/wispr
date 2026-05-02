//
//  ModelManagementView.swift
//  wispr
//
//  SwiftUI view for managing Whisper models with comprehensive download feedback.
//  Uses the shared ModelDownloadProgressView for consistent UX with onboarding.
//  Requirements: 7.2, 7.3, 7.4, 7.6, 7.7, 7.8, 7.9, 7.10, 14.3, 14.12
//

import WisprCore
import SwiftUI

// MARK: - ModelProvider UI Properties

extension ModelProvider {
    var icon: String {
        switch self {
        case .whisper: SFSymbols.providerWhisper
        case .nvidiaParakeet: SFSymbols.providerParakeet
        }
    }

    var tintColor: Color {
        switch self {
        case .whisper: .blue
        case .nvidiaParakeet: .green
        }
    }
}

/// Discriminated union for flattening grouped model data into a single `ForEach`.
private enum ModelListItem: Identifiable {
    case header(ModelProvider)
    case model(ModelInfo)

    var id: String {
        switch self {
        case .header(let provider): "header-\(provider.rawValue)"
        case .model(let model): model.id
        }
    }
}

/// View displaying all available Whisper models with download, delete, and activation controls.
///
/// Requirement 7.2: List all available models with name, size, and status.
/// Requirement 7.3: Show download status (not downloaded, downloading %, downloaded, active).
/// Requirement 14.3: Apply Liquid Glass materials.
/// Requirement 14.12: Liquid Glass translucency on window background.
struct ModelManagementView: View {
    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @Environment(StateManager.self) private var stateManager: StateManager

    /// The WhisperService actor used for model operations.
    private let whisperService: any TranscriptionEngine

    /// Local state: snapshot of models with their current statuses.
    @State private var models: [ModelInfo] = []

    /// Model IDs currently showing the download progress view.
    @State private var activeDownloads: Set<String> = []

    /// Model pending deletion confirmation.
    @State private var modelToDelete: ModelInfo?

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

    init(whisperService: any TranscriptionEngine) {
        self.whisperService = whisperService
    }

    /// Flat list of headers and model rows for a single-level `ForEach`.
    /// Using a single `ForEach` avoids macOS `OutlineListCoordinator` crashes
    /// that occur with nested `ForEach` inside `List` when data loads async.
    private var listItems: [ModelListItem] {
        var seen: [ModelProvider] = []
        var groups: [ModelProvider: [ModelInfo]] = [:]
        for model in models {
            if !seen.contains(model.provider) {
                seen.append(model.provider)
            }
            groups[model.provider, default: []].append(model)
        }
        var items: [ModelListItem] = []
        for provider in seen {
            items.append(.header(provider))
            for model in groups[provider, default: []] {
                items.append(.model(model))
            }
        }
        return items
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                ForEach(listItems) { item in
                    switch item {
                    case .header(let provider):
                        providerHeader(provider)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                    case .model(let model):
                        modelSection(for: model)
                    }
                }
            }

            Divider()

            Button("Close") {
                NSApp.keyWindow?.close()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut(.cancelAction)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .animation(theme.reduceMotion ? nil : .easeInOut(duration: 0.35), value: highlightedModelId)
        .frame(minWidth: 560, idealWidth: 620)
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
            Text("All models have been removed. Please download a model to continue using Wispr.")
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

    // MARK: - Provider Header

    @ScaledMetric(relativeTo: .body) private var providerIconSize: CGFloat = 24

    @ViewBuilder
    private func providerHeader(_ provider: ModelProvider) -> some View {
        HStack(spacing: 10) {
            Image(systemName: provider.icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(provider.tintColor.gradient)
                .frame(width: providerIconSize, height: providerIconSize)
                .background(provider.tintColor.opacity(0.12), in: Circle())

            Text(provider.rawValue)
                .font(.title3.weight(.semibold))
                .foregroundStyle(theme.primaryTextColor)

            Spacer()
        }
        .padding(.top, 6)
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(provider.rawValue) models")
    }

    // MARK: - Model Section

    /// Builds the view for a single model: either the inline download progress or the standard row.
    @ViewBuilder
    private func modelSection(for model: ModelInfo) -> some View {
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
            .padding(.horizontal, 14)
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
    private func setActiveModel(_ model: ModelInfo) async {
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
            try await stateManager.switchActiveModel(to: model.id)
            await refreshModels()
            activatingModelId = nil
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
    private func requestDelete(_ model: ModelInfo) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    /// Performs model deletion with fallback logic.
    ///
    /// Requirement 7.8: Remove model files from disk.
    /// Requirement 7.9: Switch to next smallest model before deleting active model.
    /// Requirement 7.10: Prompt to download if deleting the only model.
    private func performDelete(_ model: ModelInfo) async {
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

// MARK: - Previews

#if DEBUG
private struct ModelManagementPreview: View {
    @State private var settingsStore = PreviewMocks.makeSettingsStore()
    @State private var theme = PreviewMocks.makeTheme()

    private let whisperService: any TranscriptionEngine
    @State private var stateManager: StateManager

    init() {
        let service = PreviewMocks.makeWhisperService()
        self.whisperService = service
        self._stateManager = State(initialValue: PreviewMocks.makeStateManager(whisperService: service))
    }

    var body: some View {
        ModelManagementView(whisperService: whisperService)
            .environment(settingsStore)
            .environment(theme)
            .environment(stateManager)
            .frame(width: 620, height: 700)
    }
}

#Preview("Model Management") {
    ModelManagementPreview()
}

#Preview("Model Management - Dark") {
    ModelManagementPreview()
        .preferredColorScheme(.dark)
}
#endif
