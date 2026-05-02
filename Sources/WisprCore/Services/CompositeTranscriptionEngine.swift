//
//  CompositeTranscriptionEngine.swift
//  wispr
//
//  Aggregates multiple TranscriptionEngine instances behind a single
//  TranscriptionEngine interface, routing calls to the engine that
//  owns a given model.
//

import Foundation

public actor CompositeTranscriptionEngine: TranscriptionEngine {

    private let engines: [any TranscriptionEngine]

    /// Index of the engine whose model is currently active.
    /// We track this ourselves so cross-engine switches are clean.
    private var activeEngineIndex: Int?

    public init(engines: [any TranscriptionEngine]) {
        self.engines = engines
    }

    // MARK: - Engine Lookup

    private func engineIndex(for modelId: String) async -> Int? {
        for (i, engine) in engines.enumerated() {
            let models = await engine.availableModels()
            if models.contains(where: { $0.id == modelId }) {
                return i
            }
        }
        return nil
    }

    // MARK: - Model Management

    public func availableModels() async -> [ModelInfo] {
        var all: [ModelInfo] = []
        for engine in engines {
            let models = await engine.availableModels()
            all.append(contentsOf: models)
        }
        return all
    }

    public func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        guard let idx = await engineIndex(for: model.id) else {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
            continuation.finish(throwing: WisprError.modelDownloadFailed("No engine found for model \(model.id)"))
            return stream
        }
        let innerStream = await engines[idx].downloadModel(model)

        // Wrap so activeEngineIndex updates only after successful completion.
        let (outer, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
        let engine = self
        let task = Task {
            do {
                for try await progress in innerStream {
                    continuation.yield(progress)
                }
                await engine.setActiveEngine(idx)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in
            task.cancel()
        }
        return outer
    }

    private func setActiveEngine(_ idx: Int) async {
        if let currentIdx = activeEngineIndex, currentIdx != idx {
            await engines[currentIdx].unloadCurrentModel()
        }
        activeEngineIndex = idx
    }

    public func deleteModel(_ modelName: String) async throws {
        guard let idx = await engineIndex(for: modelName) else {
            throw WisprError.modelDeletionFailed("No engine found for model \(modelName)")
        }
        try await engines[idx].deleteModel(modelName)
        if activeEngineIndex == idx {
            if await engines[idx].activeModel() == nil {
                activeEngineIndex = nil
            }
        }
    }

    public func loadModel(_ modelName: String) async throws {
        guard let idx = await engineIndex(for: modelName) else {
            throw WisprError.modelLoadFailed("No engine found for model \(modelName)")
        }

        // Unload the previous engine to free memory before loading the new one.
        if let currentIdx = activeEngineIndex, currentIdx != idx {
            await engines[currentIdx].unloadCurrentModel()
        }

        try await engines[idx].loadModel(modelName)
        activeEngineIndex = idx
    }

    public func switchModel(to modelName: String) async throws {
        guard let idx = await engineIndex(for: modelName) else {
            throw WisprError.modelLoadFailed("No engine found for model \(modelName)")
        }

        if let currentIdx = activeEngineIndex {
            if currentIdx == idx {
                // Same engine — delegate directly
                try await engines[idx].switchModel(to: modelName)
                activeEngineIndex = idx
                return
            }
            // Different engine: unload the old backend to free memory.
            await engines[currentIdx].unloadCurrentModel()
        }

        try await engines[idx].switchModel(to: modelName)
        activeEngineIndex = idx
    }

    public func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        guard let idx = await engineIndex(for: modelName) else {
            return false
        }
        return try await engines[idx].validateModelIntegrity(modelName)
    }

    public func modelStatus(_ modelName: String) async -> ModelStatus {
        guard let idx = await engineIndex(for: modelName) else {
            return .notDownloaded
        }
        return await engines[idx].modelStatus(modelName)
    }

    public func activeModel() async -> String? {
        guard let idx = activeEngineIndex else { return nil }
        return await engines[idx].activeModel()
    }

    public func unloadCurrentModel() async {
        if let idx = activeEngineIndex {
            await engines[idx].unloadCurrentModel()
            activeEngineIndex = nil
        }
    }

    public func reloadModelWithRetry(maxAttempts: Int = 3) async throws {
        guard let idx = activeEngineIndex else {
            throw WisprError.modelLoadFailed("No active model to reload")
        }
        try await engines[idx].reloadModelWithRetry(maxAttempts: maxAttempts)
    }

    // MARK: - Transcription

    public func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        guard let idx = activeEngineIndex else {
            throw WisprError.modelNotDownloaded
        }
        return try await engines[idx].transcribe(audioSamples, language: language)
    }

    public func supportsEndOfUtteranceDetection() async -> Bool {
        guard let idx = activeEngineIndex else { return false }
        return await engines[idx].supportsEndOfUtteranceDetection()
    }

    public func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        guard let idx = activeEngineIndex else {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
            continuation.finish(throwing: WisprError.modelNotDownloaded)
            return stream
        }
        return await engines[idx].transcribeStream(audioStream, language: language)
    }
}
