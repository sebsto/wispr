//
//  ModelCatalogTests.swift
//  wisprTests
//
//  Tests for the Model Management rules in ModelCatalog: activation with
//  rollback and deletion with fallback.
//

import Foundation
import Testing
@testable import WisprApp
import WisprCore

/// An engine whose model statuses and fallback choice are set by the test.
private actor CatalogEngine: TranscriptionEngine {
    private var statuses: [String: ModelStatus]
    private let fallbackAfterDelete: String?
    private var active: String?

    init(statuses: [String: ModelStatus], fallbackAfterDelete: String? = nil) {
        self.statuses = statuses
        self.fallbackAfterDelete = fallbackAfterDelete
        self.active = statuses.first { $0.value == .active }?.key
    }

    func availableModels() async -> [ModelInfo] {
        statuses.keys.sorted().map {
            ModelInfo(
                id: $0, displayName: $0, sizeDescription: "~1 MB", qualityDescription: "test",
                estimatedSize: 1, status: .notDownloaded)
        }
    }

    func modelStatus(_ modelName: String) async -> ModelStatus {
        statuses[modelName] ?? .notDownloaded
    }

    func deleteModel(_ modelName: String) async throws {
        statuses[modelName] = .notDownloaded
        if active == modelName {
            active = fallbackAfterDelete
            if let fallbackAfterDelete { statuses[fallbackAfterDelete] = .active }
        }
    }

    func switchModel(to modelName: String) async throws {
        guard statuses[modelName] == .downloaded else { throw WisprError.modelNotDownloaded }
        if let active { statuses[active] = .downloaded }
        statuses[modelName] = .active
        active = modelName
    }

    func activeModel() async -> String? { active }

    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func loadModel(_ modelName: String) async throws {}
    func validateModelIntegrity(_ modelName: String) async throws -> Bool { true }
    func unloadCurrentModel() async {}
    func reloadModelWithRetry(maxAttempts: Int) async throws {}
    func transcribe(_ audioSamples: [Float], language: TranscriptionLanguage) async throws -> TranscriptionResult {
        TranscriptionResult(text: "", detectedLanguage: nil, duration: 0)
    }
    func transcribeStream(_ audioStream: AsyncStream<[Float]>, language: TranscriptionLanguage) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func supportsEndOfUtteranceDetection() async -> Bool { false }
}

@MainActor
@Suite("ModelCatalog")
struct ModelCatalogTests {

    private func makeSettings(active: String) -> SettingsStore {
        let store = SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.catalog.\(UUID().uuidString)")!)
        store.activeModelName = active
        return store
    }

    private func makeStateManager(engine: any TranscriptionEngine, settings: SettingsStore) -> StateManager {
        StateManager(
            audioEngine: AudioEngine(),
            whisperService: engine,
            textInsertionService: TextInsertionService(),
            textCorrectionService: TextCorrectionService(),
            hotkeyMonitor: HotkeyMonitor(),
            permissionManager: PermissionManager(),
            settingsStore: settings
        )
    }

    @Test("Activating a downloaded model makes it the active one")
    func activateSucceeds() async {
        let engine = CatalogEngine(statuses: ["a": .active, "b": .downloaded])
        let settings = makeSettings(active: "a")
        let catalog = ModelCatalog(whisperService: engine)
        await catalog.refresh()

        let ok = await catalog.activate("b", using: makeStateManager(engine: engine, settings: settings))

        #expect(ok)
        #expect(catalog.activeModelId == "b")
        #expect(settings.activeModelName == "b")
        #expect(catalog.activatingModelId == nil)
        #expect(catalog.errorMessage == nil)
    }

    @Test("A failed activation keeps the previous model and reports an error")
    func activateFailsAndRollsBack() async {
        let engine = CatalogEngine(statuses: ["a": .active, "b": .notDownloaded])
        let settings = makeSettings(active: "a")
        let catalog = ModelCatalog(whisperService: engine)
        await catalog.refresh()

        let ok = await catalog.activate("b", using: makeStateManager(engine: engine, settings: settings))

        #expect(!ok)
        #expect(catalog.activeModelId == "a")
        #expect(settings.activeModelName == "a")
        #expect(catalog.activatingModelId == nil)
        #expect(catalog.errorMessage != nil)
    }

    @Test("Deleting the active model saves the engine's fallback as active")
    func deleteActiveUsesFallback() async {
        let engine = CatalogEngine(statuses: ["a": .active, "b": .downloaded], fallbackAfterDelete: "b")
        let settings = makeSettings(active: "a")
        let catalog = ModelCatalog(whisperService: engine)
        await catalog.refresh()

        let noneLeft = await catalog.delete("a", settingsStore: settings)

        #expect(!noneLeft)
        #expect(settings.activeModelName == "b")
        #expect(catalog.activeModelId == "b")
    }

    @Test("Deleting the last model reports that none is left")
    func deleteLastModel() async {
        let engine = CatalogEngine(statuses: ["a": .active])
        let settings = makeSettings(active: "a")
        let catalog = ModelCatalog(whisperService: engine)
        await catalog.refresh()

        let noneLeft = await catalog.delete("a", settingsStore: settings)

        #expect(noneLeft)
        #expect(!catalog.hasDownloadedModel)
    }

    @Test("Deleting an inactive model leaves the active model alone")
    func deleteInactiveModel() async {
        let engine = CatalogEngine(statuses: ["a": .active, "b": .downloaded])
        let settings = makeSettings(active: "a")
        let catalog = ModelCatalog(whisperService: engine)
        await catalog.refresh()

        let noneLeft = await catalog.delete("b", settingsStore: settings)

        #expect(!noneLeft)
        #expect(settings.activeModelName == "a")
    }
}
