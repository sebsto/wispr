//
//  Qwen3ASRServiceTests.swift
//  wisprTests
//
//  Unit tests for the Qwen3-ASR engine's pure logic and catalog.
//  No model files or network are needed.
//

import Testing
import Foundation
@testable import WisprCore

@Suite("Qwen3ASRService")
struct Qwen3ASRServiceTests {

    // MARK: - Catalog

    @Test("catalog lists both variants under the Qwen provider")
    func catalog() async {
        let models = await Qwen3ASRService().availableModels()
        #expect(models.map(\.id) == [ModelInfo.KnownID.qwen3ASR06B, ModelInfo.KnownID.qwen3ASR17B])
        #expect(models.allSatisfy { $0.provider == .alibabaQwen })
        #expect(models.allSatisfy { $0.estimatedSize > 0 })
    }

    @Test("provider is derived from the model id prefix")
    func providerFromId() {
        func provider(_ id: String) -> ModelProvider {
            ModelInfo(id: id, displayName: "", sizeDescription: "", qualityDescription: "",
                      estimatedSize: 1, status: .notDownloaded).provider
        }
        #expect(provider("qwen3-asr-0.6b") == .alibabaQwen)
        #expect(provider("parakeet-v3") == .nvidiaParakeet)
        #expect(provider("tiny") == .whisper)
    }

    @Test("a model that was never downloaded reports notDownloaded")
    func statusWhenAbsent() async {
        let service = Qwen3ASRService()
        let status = await service.modelStatus("not-a-model")
        #expect(status == .notDownloaded)
    }

    @Test("transcribing without a loaded model throws modelNotDownloaded")
    func transcribeWithoutModel() async {
        let service = Qwen3ASRService()
        await #expect(throws: WisprError.self) {
            _ = try await service.transcribe(
                [Float](repeating: 0, count: 16_000),
                language: .autoDetect
            )
        }
    }

    @Test("loading an unknown model id fails")
    func loadUnknownModel() async {
        let service = Qwen3ASRService()
        await #expect(throws: WisprError.self) {
            try await service.loadModel("qwen3-asr-9000b")
        }
    }

    // MARK: - Paths

    @Test("model files live under the shared models directory in Hub layout")
    func modelPath() {
        let url = ModelPaths.qwen3ASR(repoId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit")
        #expect(url.path.hasSuffix("/models/qwen3-asr/models/aufklarer/Qwen3-ASR-0.6B-MLX-4bit"))
        #expect(url.path.hasPrefix(ModelPaths.models.path))
    }

    // MARK: - Language hint

    @Test("ISO codes become English language names")
    func languageHints() {
        #expect(Qwen3ASRService.languageHint(for: .specific(code: "fr")) == "French")
        #expect(Qwen3ASRService.languageHint(for: .pinned(code: "ja")) == "Japanese")
    }

    @Test("auto-detect and unknown codes give no hint")
    func noLanguageHint() {
        #expect(Qwen3ASRService.languageHint(for: .autoDetect) == nil)
        #expect(Qwen3ASRService.languageHint(for: .specific(code: "")) == nil)
        #expect(Qwen3ASRService.languageHint(for: .specific(code: "zzzz")) == nil)
    }

    // MARK: - Output cleanup

    @Test("cleanedText trims whitespace")
    func cleanTrim() {
        #expect(Qwen3ASRService.cleanedText("  hello world \n") == "hello world")
    }

    @Test("cleanedText drops the auto-detect language prefix")
    func cleanLanguagePrefix() {
        #expect(Qwen3ASRService.cleanedText("language French<asr_text>Bonjour") == "Bonjour")
    }

    @Test("cleanedText keeps text that merely starts with the word language")
    func cleanKeepsPlainText() {
        #expect(Qwen3ASRService.cleanedText("language is hard") == "language is hard")
    }

    // MARK: - Chunking

    @Test("empty audio gives no chunks")
    func chunksEmpty() {
        #expect(Qwen3ASRService.chunkRanges(for: []).isEmpty)
    }

    @Test("audio within one window stays whole")
    func chunksShort() {
        let samples = [Float](repeating: 0.1, count: Qwen3ASRService.maxChunkSamples)
        #expect(Qwen3ASRService.chunkRanges(for: samples) == [0..<samples.count])
    }

    @Test("long audio is split into contiguous windows no longer than the maximum")
    func chunksLong() {
        let samples = [Float](repeating: 0.1, count: 100 * Qwen3ASRService.sampleRate)
        let ranges = Qwen3ASRService.chunkRanges(for: samples)

        #expect(ranges.count >= 4)
        #expect(ranges.first?.lowerBound == 0)
        #expect(ranges.last?.upperBound == samples.count)
        for (a, b) in zip(ranges, ranges.dropFirst()) {
            #expect(a.upperBound == b.lowerBound)
        }
        #expect(ranges.allSatisfy { $0.count <= Qwen3ASRService.maxChunkSamples })
    }

    @Test("cuts land in the quietest spot near the end of a window")
    func chunksCutAtSilence() {
        let rate = Qwen3ASRService.sampleRate
        var samples = [Float](repeating: 0.5, count: 40 * rate)
        // A 100 ms pause at 27.0 s, inside the last 4 s of the first window.
        for i in (27 * rate)..<(27 * rate + rate / 10) { samples[i] = 0 }

        let first = Qwen3ASRService.chunkRanges(for: samples)[0]
        #expect(abs(first.upperBound - (27 * rate + rate / 20)) <= rate / 10)
    }
}
