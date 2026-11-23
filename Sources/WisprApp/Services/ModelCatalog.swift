//
//  ModelCatalog.swift
//  wispr
//
//  The list of transcription models shown in Model Management, with the
//  actions that change it: refresh, activate and delete.
//

import Foundation
import Observation
import WisprCore

/// Model list and model actions for the Model Management window.
///
/// The view only presents this state and forwards user actions; the rules
/// (which model is active, what happens after deleting the active model)
/// live here so they can be tested without UI.
@MainActor
@Observable
final class ModelCatalog {

    /// All known models with their current statuses.
    private(set) var models: [ModelInfo] = []

    /// The model being loaded into memory, or `nil`.
    private(set) var activatingModelId: String?

    /// A user-facing message for the last failed action, or `nil`.
    var errorMessage: String?

    private let whisperService: any TranscriptionEngine

    init(whisperService: any TranscriptionEngine) {
        self.whisperService = whisperService
    }

    /// The ID of the model whose status is `.active`, if any.
    var activeModelId: String? {
        models.first(where: {
            if case .active = $0.status { return true }
            return false
        })?.id
    }

    /// Whether at least one model is downloaded or active.
    var hasDownloadedModel: Bool {
        models.contains {
            switch $0.status {
            case .downloaded, .active: true
            default: false
            }
        }
    }

    /// Reloads every model's status from the transcription engine.
    func refresh() async {
        var allModels = await whisperService.availableModels()
        for index in allModels.indices {
            allModels[index].status = await whisperService.modelStatus(allModels[index].id)
        }
        models = allModels
    }

    /// Makes `modelId` the active model.
    ///
    /// - Returns: `true` on success. On failure the previous model stays
    ///   active and `errorMessage` is set.
    @discardableResult
    func activate(_ modelId: String, using stateManager: StateManager) async -> Bool {
        activatingModelId = modelId
        defer { activatingModelId = nil }
        do {
            try await stateManager.switchActiveModel(to: modelId)
            await refresh()
            return true
        } catch {
            errorMessage = "Failed to activate model: \(error.localizedDescription)"
            return false
        }
    }

    /// Deletes a model from disk.
    ///
    /// When the deleted model was the active one, the engine picks a fallback
    /// and it is saved as the new active model.
    ///
    /// - Returns: `true` when no downloaded model is left afterwards, so the
    ///   caller can prompt the user to download one.
    func delete(_ modelId: String, settingsStore: SettingsStore) async -> Bool {
        do {
            try await whisperService.deleteModel(modelId)
            if settingsStore.activeModelName == modelId,
               let newActive = await whisperService.activeModel() {
                settingsStore.activeModelName = newActive
            }
            await refresh()
            return !hasDownloadedModel
        } catch {
            errorMessage = "Failed to delete model: \(error.localizedDescription)"
            return false
        }
    }

    /// Updates one model's status in place, e.g. when a download finishes.
    func updateStatus(_ modelId: String, to status: ModelStatus) {
        if let index = models.firstIndex(where: { $0.id == modelId }) {
            models[index].status = status
        }
    }
}
