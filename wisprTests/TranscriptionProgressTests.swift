//
//  TranscriptionProgressTests.swift
//  wisprTests
//
//  Tests for the additive transcription-progress reporting in WisprCore.
//
//  The central guarantee being protected here is that the progress plumbing is
//  additive: engines that don't implement the reporting overload keep working
//  through the protocol's default implementation, so neither the GUI app nor the
//  existing mock had to change.
//

import Testing
import Foundation
import WisprCore

// MARK: - Mock that does report progress

/// Reports a fixed sequence of positions, so forwarding can be asserted.
private actor ProgressReportingEngine: TranscriptionEngine {
    let models: [ModelInfo]
    private var _activeModel: String?
    private let positions: [Double]
    private let totalSeconds: Double

    init(models: [ModelInfo], positions: [Double], totalSeconds: Double) {
        self.models = models
        self.positions = positions
        self.totalSeconds = totalSeconds
    }

    func availableModels() async -> [ModelInfo] { models }

    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
        continuation.finish()
        return stream
    }

    func deleteModel(_ modelName: String) async throws {}
    func loadModel(_ modelName: String) async throws { _activeModel = modelName }
    func switchModel(to modelName: String) async throws { _activeModel = modelName }
    func unloadCurrentModel() async { _activeModel = nil }
    func validateModelIntegrity(_ modelName: String) async throws -> Bool { true }
    func modelStatus(_ modelName: String) async -> ModelStatus {
        _activeModel == modelName ? .active : .downloaded
    }
    func activeModel() async -> String? { _activeModel }
    func reloadModelWithRetry(maxAttempts: Int) async throws {}
    func supportsEndOfUtteranceDetection() async -> Bool { false }

    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: "reporting", detectedLanguage: nil, duration: 0.1)
    }

    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage,
        onProgress: TranscriptionProgressHandler?
    ) async throws -> TranscriptionResult {
        for position in positions {
            onProgress?(ProgressUpdate(
                processedSeconds: position,
                totalSeconds: totalSeconds,
                textTail: nil
            ))
        }
        return TranscriptionResult(text: "reporting", detectedLanguage: nil, duration: 0.1)
    }

    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        continuation.finish()
        return stream
    }
}

/// Deliberately implements ONLY the two-argument `transcribe`, exercising the
/// protocol's default implementation of the reporting overload.
private actor NonReportingEngine: TranscriptionEngine {
    let models: [ModelInfo]
    private var _activeModel: String?

    init(models: [ModelInfo]) { self.models = models }

    func availableModels() async -> [ModelInfo] { models }

    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
        continuation.finish()
        return stream
    }

    func deleteModel(_ modelName: String) async throws {}
    func loadModel(_ modelName: String) async throws { _activeModel = modelName }
    func switchModel(to modelName: String) async throws { _activeModel = modelName }
    func unloadCurrentModel() async { _activeModel = nil }
    func validateModelIntegrity(_ modelName: String) async throws -> Bool { true }
    func modelStatus(_ modelName: String) async -> ModelStatus {
        _activeModel == modelName ? .active : .downloaded
    }
    func activeModel() async -> String? { _activeModel }
    func reloadModelWithRetry(maxAttempts: Int) async throws {}
    func supportsEndOfUtteranceDetection() async -> Bool { false }

    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        TranscriptionResult(text: "non-reporting", detectedLanguage: nil, duration: 0.1)
    }

    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
        continuation.finish()
        return stream
    }
}

private func makeModel(_ id: String) -> ModelInfo {
    ModelInfo(
        id: id,
        displayName: id,
        sizeDescription: "~100 MB",
        qualityDescription: "test",
        estimatedSize: 100 * 1024 * 1024,
        status: .notDownloaded
    )
}

// MARK: - ProgressUpdate

@Suite("ProgressUpdate")
struct ProgressUpdateTests {

    @Test("Fraction is nil when the total is unknown")
    func fractionNilWithoutTotal() {
        let update = ProgressUpdate(processedSeconds: 42)
        #expect(update.fraction == nil)
    }

    @Test("Fraction is nil for a zero or negative total rather than dividing by zero")
    func fractionNilForZeroTotal() {
        #expect(ProgressUpdate(processedSeconds: 10, totalSeconds: 0).fraction == nil)
        #expect(ProgressUpdate(processedSeconds: 10, totalSeconds: -5).fraction == nil)
    }

    @Test("Fraction is the ratio of processed to total")
    func fractionIsRatio() throws {
        let update = ProgressUpdate(processedSeconds: 25, totalSeconds: 100)
        let fraction = try #require(update.fraction)
        #expect(abs(fraction - 0.25) < 0.0001)
    }

    @Test("Fraction is clamped to 0...1 so overshoot can't break a progress bar")
    func fractionIsClamped() {
        #expect(ProgressUpdate(processedSeconds: 150, totalSeconds: 100).fraction == 1.0)
        #expect(ProgressUpdate(processedSeconds: -20, totalSeconds: 100).fraction == 0.0)
    }

    @Test("Text tail is carried through untouched")
    func textTailPreserved() {
        let update = ProgressUpdate(processedSeconds: 1, totalSeconds: 2, textTail: "hello there")
        #expect(update.textTail == "hello there")
    }
}

// MARK: - Protocol default implementation

@Suite("TranscriptionEngine progress overload", .serialized)
struct TranscriptionEngineProgressTests {

    @Test("An engine that doesn't implement the overload still transcribes via the default")
    func defaultImplementationForwards() async throws {
        let engine = NonReportingEngine(models: [makeModel("model-a")])
        try await engine.loadModel("model-a")

        let collector = ProgressUpdateCollector()
        let result = try await engine.transcribe(
            [0.0, 0.1],
            language: .autoDetect,
            onProgress: { collector.record($0) }
        )

        // The transcript still comes back...
        #expect(result.text == "non-reporting")
        // ...and the handler is simply never called, which is what makes the
        // consumer's indeterminate fallback necessary.
        #expect(collector.updates.isEmpty)
    }

    @Test("An engine that does implement the overload reports positions")
    func reportingEngineReportsPositions() async throws {
        let engine = ProgressReportingEngine(
            models: [makeModel("model-a")],
            positions: [30, 60, 90],
            totalSeconds: 120
        )
        try await engine.loadModel("model-a")

        let collector = ProgressUpdateCollector()
        let result = try await engine.transcribe(
            [0.0],
            language: .autoDetect,
            onProgress: { collector.record($0) }
        )

        #expect(result.text == "reporting")
        #expect(collector.updates.map(\.processedSeconds) == [30, 60, 90])
        #expect(collector.updates.last?.fraction == 0.75)
    }

    @Test("Passing no handler is supported and changes nothing")
    func nilHandlerIsFine() async throws {
        let engine = ProgressReportingEngine(
            models: [makeModel("model-a")],
            positions: [10],
            totalSeconds: 20
        )
        try await engine.loadModel("model-a")

        let result = try await engine.transcribe([0.0], language: .autoDetect, onProgress: nil)
        #expect(result.text == "reporting")
    }
}

// MARK: - Composite forwarding

@Suite("CompositeTranscriptionEngine progress forwarding", .serialized)
struct CompositeProgressForwardingTests {

    @Test("Progress is forwarded from the active engine")
    func forwardsProgressFromActiveEngine() async throws {
        let engine = ProgressReportingEngine(
            models: [makeModel("model-a")],
            positions: [15, 45],
            totalSeconds: 60
        )
        let composite = CompositeTranscriptionEngine(engines: [engine])
        try await composite.loadModel("model-a")

        let collector = ProgressUpdateCollector()
        let result = try await composite.transcribe(
            [0.0],
            language: .autoDetect,
            onProgress: { collector.record($0) }
        )

        #expect(result.text == "reporting")
        #expect(collector.updates.map(\.processedSeconds) == [15, 45])
    }

    @Test("Progress is routed to the engine owning the active model, not the first one")
    func routesToCorrectEngine() async throws {
        let silent = NonReportingEngine(models: [makeModel("model-a")])
        let reporting = ProgressReportingEngine(
            models: [makeModel("model-b")],
            positions: [5],
            totalSeconds: 10
        )
        let composite = CompositeTranscriptionEngine(engines: [silent, reporting])
        try await composite.loadModel("model-b")

        let collector = ProgressUpdateCollector()
        let result = try await composite.transcribe(
            [0.0],
            language: .autoDetect,
            onProgress: { collector.record($0) }
        )

        #expect(result.text == "reporting")
        #expect(collector.updates.count == 1)
    }

    @Test("Transcribing with no model loaded throws instead of reporting progress")
    func throwsWithoutActiveModel() async {
        let engine = ProgressReportingEngine(
            models: [makeModel("model-a")],
            positions: [1],
            totalSeconds: 2
        )
        let composite = CompositeTranscriptionEngine(engines: [engine])

        let collector = ProgressUpdateCollector()
        await #expect(throws: WisprError.self) {
            try await composite.transcribe(
                [0.0],
                language: .autoDetect,
                onProgress: { collector.record($0) }
            )
        }
        #expect(collector.updates.isEmpty)
    }
}
