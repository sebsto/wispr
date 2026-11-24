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
        case .alibabaQwen: SFSymbols.providerQwen
        }
    }

    var tintColor: Color {
        switch self {
        case .whisper: .blue
        case .nvidiaParakeet: .green
        case .alibabaQwen: .orange
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

    /// Model list and model actions (refresh, activate, delete).
    @State private var catalog: ModelCatalog

    private var models: [ModelInfo] { catalog.models }

    /// The provider shown in the detail pane.
    @State private var selectedProvider: ModelProvider?

    /// Model IDs currently showing the download progress view.
    @State private var activeDownloads: Set<String> = []

    /// Model pending deletion confirmation.
    @State private var modelToDelete: ModelInfo?

    /// Whether the delete confirmation dialog is shown.
    @State private var showDeleteConfirmation = false

    /// Whether a "no models" alert is shown after deleting the last model.
    @State private var showNoModelsAlert = false


    /// Tracks which model ID currently shows the green highlight overlay.
    /// Drives the animated transition when switching active models.
    @State private var highlightedModelId: String?

    /// Namespace used by `matchedGeometryEffect` so the green highlight
    /// slides from one row to another instead of fading independently.
    @Namespace private var highlightNamespace

    /// Closes the window hosting this view. Supplied by the owner of the
    /// window, so Close always closes this window and not whichever is key.
    private let onClose: (() -> Void)?

    init(whisperService: any TranscriptionEngine, onClose: (() -> Void)? = nil) {
        self.whisperService = whisperService
        self.onClose = onClose
        _catalog = State(initialValue: ModelCatalog(whisperService: whisperService))
    }

    /// Providers that have at least one model, in a stable order.
    private var providers: [ModelProvider] {
        ModelProvider.allCases.filter { provider in models.contains { $0.provider == provider } }
    }

    private func models(for provider: ModelProvider) -> [ModelInfo] {
        models.filter { $0.provider == provider }
    }

    private func hasActiveModel(_ provider: ModelProvider) -> Bool {
        models(for: provider).contains {
            if case .active = $0.status { return true }
            return false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                providerSidebar
                Divider()
                detailPane
            }

            Divider()

            Button("Close") {
                onClose?()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .keyboardShortcut(.cancelAction)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .animation(theme.reduceMotion ? nil : .easeInOut(duration: 0.35), value: highlightedModelId)
        .frame(minWidth: 740, idealWidth: 780, minHeight: 480)
        .liquidGlassPanel()
        .navigationTitle("Model Management")
        .task {
            await refreshModels()
            // Open on the provider of the active model, else the first one.
            if selectedProvider == nil {
                selectedProvider = providers.first(where: hasActiveModel) ?? providers.first
            }
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
            get: { catalog.errorMessage != nil },
            set: { if !$0 { catalog.errorMessage = nil } }
        )) {
            Button("OK") { catalog.errorMessage = nil }
        } message: {
            if let errorMessage = catalog.errorMessage {
                Text(errorMessage)
            }
        }
    }

    // MARK: - Provider Sidebar

    private var providerSidebar: some View {
        List(selection: $selectedProvider) {
            Section("Providers") {
                ForEach(providers, id: \.self) { provider in
                    providerRow(provider)
                        .tag(provider)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
        .accessibilityLabel("Model providers")
    }

    private func providerRow(_ provider: ModelProvider) -> some View {
        let isActive = hasActiveModel(provider)
        return HStack {
            Label {
                Text(provider.rawValue)
            } icon: {
                Image(systemName: provider.icon)
                    .foregroundStyle(provider.tintColor.gradient)
            }
            Spacer()
            if isActive {
                Image(systemName: SFSymbols.checkmarkPlain)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(theme.successColor)
                    .help("The active model is from this provider")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isActive ? "\(provider.rawValue), has the active model" : provider.rawValue)
    }

    // MARK: - Detail Pane

    /// Model list for the selected provider.
    ///
    /// Every provider's list stays in the view tree and only the selected one
    /// is shown: a model download runs inside its row's `.task`, so removing
    /// the row by switching provider would cancel the download.
    private var detailPane: some View {
        ZStack {
            ForEach(providers, id: \.self) { provider in
                let isSelected = provider == selectedProvider
                List {
                    ForEach(models(for: provider)) { model in
                        modelSection(for: model)
                    }
                }
                .opacity(isSelected ? 1 : 0)
                .allowsHitTesting(isSelected)
                .accessibilityHidden(!isSelected)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                isActivating: catalog.activatingModelId == model.id,
                isHighlighted: highlightedModelId == model.id,
                namespace: highlightNamespace,
                onDownload: {
                    activeDownloads.insert(model.id)
                    catalog.updateStatus(model.id, to: .downloading(progress: 0.0))
                },
                onSetActive: { await setActiveModel(model) },
                onDelete: { requestDelete(model) }
            )
        }
    }

    // MARK: - Actions

    /// Refreshes the model list and keeps the green highlight on the active model.
    private func refreshModels() async {
        await catalog.refresh()
        let activeId = catalog.activeModelId
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

        await catalog.activate(model.id, using: stateManager)
        // On failure this moves the highlight back to the model still active.
        highlightedModelId = catalog.activeModelId
    }

    /// Shows the delete confirmation dialog.
    private func requestDelete(_ model: ModelInfo) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    /// Deletes a model, then prompts for a download if none is left.
    ///
    /// Requirement 7.8: Remove model files from disk.
    /// Requirement 7.9: Switch to next smallest model before deleting active model.
    /// Requirement 7.10: Prompt to download if deleting the only model.
    private func performDelete(_ model: ModelInfo) async {
        if await catalog.delete(model.id, settingsStore: settingsStore) {
            showNoModelsAlert = true
        }
        highlightedModelId = catalog.activeModelId
        modelToDelete = nil
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
