//
//  CompositeTranscriptionEngineTests.swift
//  wisprTests
//
//  Unit tests for CompositeTranscriptionEngine bug fixes.
//

import Testing
import Foundation
@testable import wispr

// MARK: - Mock Engine

/// A fully controllable mock TranscriptionEngine for testing CompositeTranscriptionEngine.
actor MockTranscriptionEngine: TranscriptionEngine {
    let models: [ModelInfo]
    private var _activeModel: String?
    private var downloadBehavior: DownloadBehavior = .succeedImmediately

    enum DownloadBehavior {
        case succeedImmediately
        case failWith(Error)
        /// Yields progress via the continuation, then waits for `finishDownload()` to be called.
        case controlled
    }

    private var downloadContinuation: AsyncThrowingStream<DownloadProgress, Error>.Continuation?
    private var downloadFinished = false

    init(models: [ModelInfo], activeModel: String? = nil) {
        self.models = models
        self._activeModel = activeModel
    }

    func setDownloadBehavior(_ behavior: DownloadBehavior) {
        self.downloadBehavior = behavior
    }

    /// Call to complete a `.controlled` download successfully.
    func finishDownload() {
        downloadContinuation?.finish()
        downloadContinuation = nil
        downloadFinished = true
    }

    /// Call to fail a `.controlled` download.
    func failDownload(_ error: Error) {
        downloadContinuation?.finish(throwing: error)
        downloadContinuation = nil
        downloadFinished = true
    }

    func availableModels() async -> [ModelInfo] {
        models
    }

    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        let modelId = await model.id
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)

        switch downloadBehavior {
        case .succeedImmediately:
            _activeModel = modelId
            continuation.yield(DownloadProgress(phase: .downloading, fractionCompleted: 0.0, bytesDownloaded: 0, totalBytes: 100))
            continuation.yield(DownloadProgress(phase: .warmingUp, fractionCompleted: 1.0, bytesDownloaded: 100, totalBytes: 100))
            continuation.finish()

        case .failWith(let error):
            continuation.yield(DownloadProgress(phase: .downloading, fractionCompleted: 0.0, bytesDownloaded: 0, totalBytes: 100))
            continuation.finish(throwing: error)

        case .controlled:
            downloadFinished = false
            downloadContinuation = continuation
            continuation.yield(DownloadProgress(phase: .downloading, fractionCompleted: 0.0, bytesDownloaded: 0, totalBytes: 100))
        }

        return stream
    }

    func deleteModel(_ modelName: String) async throws {
        if _activeModel == modelName {
            _activeModel = nil
        }
    }

    func loadModel(_ modelName: String) async throws {
        _activeModel = modelName
    }

    func switchModel(to modelName: String) async throws {
        _activeModel = modelName
    }

    func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        true
    }

    func modelStatus(_ modelName: String) async -> ModelStatus {
        if _activeModel == modelName { return .active }
        return .downloaded
    }

    func activeModel() async -> String? {
        _activeModel
    }

    func unloadCurrentModel() async {
        _activeModel = nil
    }

    func reloadModelWithRetry(maxAttempts: Int) async throws {
        // no-op
    }

    func transcribe(_ audioSamples: [Float], language: TranscriptionLanguage) async throws -> TranscriptionResult {
        guard _activeModel != nil else { throw WisprError.modelNotDownloaded }
        return TranscriptionResult(text: "mock", detectedLanguage: nil, duration: 0.1)
    }

    func transcribeStream(_ audioStream: AsyncStream<[Float]>, language: TranscriptionLanguage) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        guard _activeModel != nil else {
            continuation.finish(throwing: WisprError.modelNotDownloaded)
            return stream
        }
        continuation.yield(TranscriptionResult(text: "mock", detectedLanguage: nil, duration: 0.1))
        continuation.finish()
        return stream
    }
}

// MARK: - Helper

private func makeModel(_ id: String) -> ModelInfo {
    ModelInfo(id: id, displayName: id, sizeDescription: "~100 MB", qualityDescription: "test", estimatedSize: 100 * 1024 * 1024, status: .notDownloaded)
}

// MARK: - Tests

@Suite("CompositeTranscriptionEngine Tests", .serialized)
struct CompositeTranscriptionEngineTests {

    // MARK: - Bug 1: activeEngineIndex deferred until download succeeds

    @Test("Download does not switch active engine while download is in progress")
    func downloadDefersActiveEngineSwitch() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])
        await engineB.setDownloadBehavior(.controlled)

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])

        // Manually set engine A as active by loading its model
        try await composite.loadModel("model-a")
        let activeBefore = await composite.activeModel()
        #expect(activeBefore == "model-a")

        // Start downloading model-b (controlled — won't finish yet)
        let stream = await composite.downloadModel(makeModel("model-b"))

        // Consume the initial progress event that was yielded synchronously
        var iterator = stream.makeAsyncIterator()
        let firstProgress = try await iterator.next()
        #expect(firstProgress != nil)

        // While download is in-progress, active model should still be model-a
        let activeDuring = await composite.activeModel()
        #expect(activeDuring == "model-a")

        // Transcription should still work with engine A during download
        let result = try await composite.transcribe([Float](repeating: 0, count: 100), language: .autoDetect)
        #expect(result.text == "mock")

        // Clean up the controlled download
        await engineB.finishDownload()
        while let _ = try await iterator.next() { }
    }

    @Test("Download failure does not switch active engine")
    func downloadFailureKeepsCurrentEngine() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])
        await engineB.setDownloadBehavior(.failWith(WisprError.modelDownloadFailed("network error")))

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        try await composite.loadModel("model-a")

        let stream = await composite.downloadModel(makeModel("model-b"))

        // Consume the stream (it will throw)
        do {
            for try await _ in stream { }
            Issue.record("Expected download stream to throw")
        } catch {
            // Expected
        }

        // Active model should still be model-a
        let active = await composite.activeModel()
        #expect(active == "model-a")
    }

    // MARK: - Delete behavior

    @Test("Deleting active model does not cross-engine fallback to stale backend")
    func deleteActiveDoesNotReactivateStaleBackend() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")], activeModel: "model-b")

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])

        // Set engine A as active — engine B still reports model-b as active internally
        try await composite.loadModel("model-a")

        // Delete model-a — should NOT reactivate engine B's stale model
        try await composite.deleteModel("model-a")

        let activeAfter = await composite.activeModel()
        #expect(activeAfter == nil)
    }

    @Test("Deleting active model results in nil active model")
    func deleteActiveModelResultsInNil() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        try await composite.loadModel("model-a")

        try await composite.deleteModel("model-a")

        let activeAfter = await composite.activeModel()
        #expect(activeAfter == nil)
    }

    @Test("Deleting non-active model does not change active engine")
    func deleteNonActiveModelKeepsActiveEngine() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")], activeModel: "model-b")

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        try await composite.loadModel("model-a")

        // Delete model-b (not the active engine)
        try await composite.deleteModel("model-b")

        let active = await composite.activeModel()
        #expect(active == "model-a")
    }

    // MARK: - Status after cross-engine switch

    @Test("After switching engines, old engine is unloaded and reports downloaded")
    func switchEnginesUnloadsOldEngineStatus() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])

        // Start with engine A active
        try await composite.loadModel("model-a")
        #expect(await composite.modelStatus("model-a") == .active)

        // Switch to engine B — engine A should be unloaded
        try await composite.loadModel("model-b")

        // Engine B's model should be .active
        #expect(await composite.modelStatus("model-b") == .active)

        // Engine A was unloaded, so it reports .downloaded (not .active)
        let statusA = await composite.modelStatus("model-a")
        #expect(statusA == .downloaded)
    }

    // MARK: - Cross-engine unload on switch

    @Test("Loading model on different engine unloads the previous engine")
    func loadModelUnloadsPreviousEngine() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        try await composite.loadModel("model-a")

        // Engine A has model-a loaded
        let engineAActiveBefore = await engineA.activeModel()
        #expect(engineAActiveBefore == "model-a")

        // Switch to engine B — should unload engine A
        try await composite.loadModel("model-b")

        let engineAActiveAfter = await engineA.activeModel()
        #expect(engineAActiveAfter == nil)

        let engineBActive = await engineB.activeModel()
        #expect(engineBActive == "model-b")
    }

    @Test("switchModel across engines unloads the previous engine")
    func switchModelUnloadsPreviousEngine() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        try await composite.loadModel("model-a")

        // Switch to model-b on engine B
        try await composite.switchModel(to: "model-b")

        // Engine A should be unloaded
        let engineAActive = await engineA.activeModel()
        #expect(engineAActive == nil)

        // Engine B should be active
        let compositeActive = await composite.activeModel()
        #expect(compositeActive == "model-b")
    }

    // MARK: - Bug 1 + Transcription interaction

    @Test("Transcription works with old engine while new download is in progress")
    func transcriptionWorksDuringDownload() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")], activeModel: "model-a")
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])
        await engineB.setDownloadBehavior(.controlled)

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        try await composite.loadModel("model-a")

        // Start download of model-b (won't complete)
        let stream = await composite.downloadModel(makeModel("model-b"))

        // Drain available progress
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()

        // Transcription should route to engine A
        let result = try await composite.transcribe([Float](repeating: 0, count: 100), language: .autoDetect)
        #expect(result.text == "mock")

        // Cleanup
        await engineB.finishDownload()
        while let _ = try await iterator.next() { }
    }

    // MARK: - Routing basics

    @Test("Available models aggregates from all engines")
    func availableModelsAggregates() async {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")])
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b"), makeModel("model-c")])

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])
        let models = await composite.availableModels()

        #expect(models.count == 3)
        #expect(models.map(\.id) == ["model-a", "model-b", "model-c"])
    }

    @Test("Download for unknown model returns error stream")
    func downloadUnknownModelReturnsError() async {
        let engine = MockTranscriptionEngine(models: [makeModel("model-a")])
        let composite = CompositeTranscriptionEngine(engines: [engine])

        let stream = await composite.downloadModel(makeModel("unknown"))
        do {
            for try await _ in stream { }
            Issue.record("Expected error for unknown model")
        } catch let error as WisprError {
            if case .modelDownloadFailed(let msg) = error {
                #expect(msg.contains("unknown"))
            } else {
                Issue.record("Expected modelDownloadFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected WisprError, got \(error)")
        }
    }

    @Test("Transcription throws when no engine is active")
    func transcriptionThrowsWhenNoActiveEngine() async {
        let engine = MockTranscriptionEngine(models: [makeModel("model-a")])
        let composite = CompositeTranscriptionEngine(engines: [engine])

        do {
            _ = try await composite.transcribe([Float](repeating: 0, count: 100), language: .autoDetect)
            Issue.record("Expected modelNotDownloaded error")
        } catch let error as WisprError {
            #expect(error == .modelNotDownloaded)
        } catch {
            Issue.record("Expected WisprError, got \(error)")
        }
    }

    @Test("Successful download switches active engine and enables transcription")
    func successfulDownloadEnablesTranscription() async throws {
        let engineA = MockTranscriptionEngine(models: [makeModel("model-a")])
        let engineB = MockTranscriptionEngine(models: [makeModel("model-b")])
        // engineB defaults to succeedImmediately

        let composite = CompositeTranscriptionEngine(engines: [engineA, engineB])

        let stream = await composite.downloadModel(makeModel("model-b"))
        for try await _ in stream { }

        let active = await composite.activeModel()
        #expect(active == "model-b")

        let result = try await composite.transcribe([Float](repeating: 0, count: 100), language: .autoDetect)
        #expect(result.text == "mock")
    }
}
