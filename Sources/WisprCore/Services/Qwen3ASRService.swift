//
//  Qwen3ASRService.swift
//  wispr
//
//  Actor encapsulating the Qwen3-ASR model lifecycle and batch transcription.
//  Runs the model on MLX through the speech-swift `Qwen3ASR` module.
//  Conforms to TranscriptionEngine so it can be used interchangeably with
//  WhisperService and ParakeetService.
//

import Foundation
import Qwen3ASR
import os

public actor Qwen3ASRService {

    // MARK: - Catalog

    /// Static description of one Qwen3-ASR variant.
    nonisolated struct Variant: Sendable {
        let info: ModelInfo
        /// Hugging Face repository holding the MLX weights.
        let repoId: String
    }

    nonisolated static let variants: [Variant] = [
        Variant(
            info: ModelInfo(
                id: ModelInfo.KnownID.qwen3ASR06B,
                displayName: "Qwen3-ASR 0.6B",
                sizeDescription: "~710 MB",
                qualityDescription: "Fast, multilingual (52 languages and dialects)",
                estimatedSize: 713 * 1000 * 1000,
                status: .notDownloaded
            ),
            repoId: "aufklarer/Qwen3-ASR-0.6B-MLX-4bit"
        ),
        Variant(
            info: ModelInfo(
                id: ModelInfo.KnownID.qwen3ASR17B,
                displayName: "Qwen3-ASR 1.7B",
                sizeDescription: "~2.5 GB",
                qualityDescription: "Slower, higher accuracy, multilingual (52 languages and dialects)",
                estimatedSize: 2468 * 1000 * 1000,
                status: .notDownloaded
            ),
            repoId: "aufklarer/Qwen3-ASR-1.7B-MLX-8bit"
        ),
    ]

    nonisolated static func variant(for modelId: String) -> Variant? {
        variants.first { $0.info.id == modelId }
    }

    // MARK: - Audio constants

    /// Sample rate Qwen3-ASR expects.
    nonisolated static let sampleRate = 16_000

    /// Audio shorter than this (0.5 s) is treated as empty.
    nonisolated static let minimumSamples = 8_000

    /// Longest window sent to the model in one call (30 s).
    nonisolated static let maxChunkSamples = 30 * sampleRate

    // MARK: - State

    private var model: Qwen3ASRModel?
    private var activeModelName: String?
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public init() {}

    // MARK: - Helpers

    /// True when the weights and config for `variant` are on disk.
    nonisolated static func filesExist(for variant: Variant) -> Bool {
        let dir = ModelPaths.qwen3ASR(repoId: variant.repoId)
        let fm = FileManager.default
        return fm.fileExists(atPath: dir.appendingPathComponent("config.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("vocab.json").path)
            && fm.fileExists(atPath: dir.appendingPathComponent("model.safetensors").path)
    }

    /// Model IDs whose files are complete on disk, with their directories.
    /// Used by the CLI, which reads models the GUI app downloaded.
    public nonisolated static func downloadedModels() -> [(id: String, directory: URL)] {
        variants.filter(filesExist(for:)).map {
            (id: $0.info.id, directory: ModelPaths.qwen3ASR(repoId: $0.repoId))
        }
    }

    /// Qwen3-ASR takes its language hint as an English language name
    /// ("French"), not an ISO code. Returns nil for auto-detect or when the
    /// code has no known name.
    nonisolated static func languageHint(for language: TranscriptionLanguage) -> String? {
        guard let code = language.languageCode, !code.isEmpty else { return nil }
        let name = Locale(identifier: "en_US").localizedString(forLanguageCode: code)
        guard let name, name.caseInsensitiveCompare(code) != .orderedSame else { return nil }
        return name
    }

    /// Splits `samples` into windows of at most `maxChunkSamples`.
    ///
    /// Each cut lands on the quietest 100 ms frame in the last 4 s of its
    /// window, so words are less likely to be split in half.
    nonisolated static func chunkRanges(for samples: [Float]) -> [Range<Int>] {
        let total = samples.count
        guard total > maxChunkSamples else { return total > 0 ? [0..<total] : [] }

        let frame = sampleRate / 10
        let searchSpan = 4 * sampleRate
        var ranges: [Range<Int>] = []
        var start = 0

        while total - start > maxChunkSamples {
            let windowEnd = start + maxChunkSamples
            var bestCut = windowEnd
            var bestEnergy = Float.greatestFiniteMagnitude
            var frameStart = windowEnd - searchSpan
            while frameStart + frame <= windowEnd {
                var energy: Float = 0
                for i in frameStart..<(frameStart + frame) {
                    energy += samples[i] * samples[i]
                }
                if energy < bestEnergy {
                    bestEnergy = energy
                    bestCut = frameStart + frame / 2
                }
                frameStart += frame
            }
            ranges.append(start..<bestCut)
            start = bestCut
        }
        ranges.append(start..<total)
        return ranges
    }

    /// Strips the "language XX" prefix auto-detection can leave in the output.
    nonisolated static func cleanedText(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("language "), let marker = text.range(of: "<asr_text>") {
            text = String(text[marker.upperBound...])
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func loadModelFromDisk(
        _ variant: Variant,
        offline: Bool,
        progressHandler: (@Sendable (Double, String) -> Void)? = nil
    ) async throws {
        let loaded = try await Qwen3ASRModel.fromPretrained(
            modelId: variant.repoId,
            cacheDir: ModelPaths.qwen3ASR(repoId: variant.repoId),
            offlineMode: offline,
            progressHandler: progressHandler
        )
        model = loaded
        Log.whisperService.debug("Qwen3ASRService — loaded \(variant.info.id)")
    }

    private func unload() {
        model = nil
        activeModelName = nil
        Log.whisperService.debug("Qwen3ASRService — model unloaded")
    }
}

// MARK: - TranscriptionEngine Conformance

extension Qwen3ASRService: TranscriptionEngine {

    public func availableModels() async -> [ModelInfo] {
        Self.variants.map(\.info)
    }

    public func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)

        guard let variant = Self.variant(for: model.id) else {
            continuation.finish(throwing: WisprError.modelDownloadFailed("Unknown model \(model.id)"))
            return stream
        }
        guard downloadTasks[model.id] == nil else {
            continuation.finish(throwing: WisprError.modelDownloadFailed("Model \(model.displayName) is already being downloaded"))
            return stream
        }

        let estimatedSize = model.estimatedSize

        let task = Task {
            defer { self.downloadTasks.removeValue(forKey: model.id) }
            do {
                continuation.yield(DownloadProgress(
                    phase: .downloading, fractionCompleted: 0, bytesDownloaded: 0, totalBytes: estimatedSize
                ))

                // The SDK reports 0...0.8 while fetching files, then 0.8...1.0
                // while it reads weights into memory.
                let downloadShare = 0.8
                try await self.loadModelFromDisk(variant, offline: false) { fraction, _ in
                    if fraction < downloadShare {
                        let download = fraction / downloadShare
                        continuation.yield(DownloadProgress(
                            phase: .downloading,
                            fractionCompleted: download,
                            bytesDownloaded: Int64(Double(estimatedSize) * download),
                            totalBytes: estimatedSize
                        ))
                    } else {
                        continuation.yield(DownloadProgress(
                            phase: .loadingModel,
                            fractionCompleted: 1.0,
                            bytesDownloaded: estimatedSize,
                            totalBytes: estimatedSize
                        ))
                    }
                }
                self.activeModelName = model.id

                continuation.yield(DownloadProgress(
                    phase: .warmingUp, fractionCompleted: 1.0, bytesDownloaded: estimatedSize, totalBytes: estimatedSize
                ))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: WisprError.modelDownloadFailed("Download of \(model.displayName) was cancelled"))
            } catch {
                continuation.finish(throwing: WisprError.modelDownloadFailed("Failed to download \(model.displayName): \(error.localizedDescription)"))
            }
        }
        downloadTasks[model.id] = task
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func deleteModel(_ modelName: String) async throws {
        downloadTasks[modelName]?.cancel()
        downloadTasks.removeValue(forKey: modelName)

        guard let variant = Self.variant(for: modelName) else { return }
        if activeModelName == modelName { unload() }

        let dir = ModelPaths.qwen3ASR(repoId: variant.repoId)
        if FileManager.default.fileExists(atPath: dir.path) {
            do {
                try FileManager.default.removeItem(at: dir)
            } catch {
                throw WisprError.modelDeletionFailed("Failed to delete \(variant.info.displayName): \(error.localizedDescription)")
            }
        }
        Log.whisperService.debug("Qwen3ASRService — model \(modelName) deleted")
    }

    public func loadModel(_ modelName: String) async throws {
        guard let variant = Self.variant(for: modelName) else {
            throw WisprError.modelLoadFailed("Unknown model \(modelName)")
        }
        guard activeModelName != modelName || model == nil else { return }
        guard Self.filesExist(for: variant) else { throw WisprError.modelNotDownloaded }

        do {
            try await loadModelFromDisk(variant, offline: true)
            activeModelName = modelName
        } catch {
            throw WisprError.modelLoadFailed("Failed to load \(variant.info.displayName): \(error.localizedDescription)")
        }
    }

    public func switchModel(to modelName: String) async throws {
        guard activeModelName != modelName || model == nil else { return }
        unload()
        try await loadModel(modelName)
    }

    public func unloadCurrentModel() async {
        unload()
    }

    public func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        guard let variant = Self.variant(for: modelName) else { return false }
        return Self.filesExist(for: variant)
    }

    public func modelStatus(_ modelName: String) async -> ModelStatus {
        guard let variant = Self.variant(for: modelName) else { return .notDownloaded }
        if downloadTasks[modelName] != nil { return .downloading(progress: 0.0) }
        guard Self.filesExist(for: variant) else { return .notDownloaded }
        return (modelName == activeModelName && model != nil) ? .active : .downloaded
    }

    public func activeModel() async -> String? {
        activeModelName
    }

    public func reloadModelWithRetry(maxAttempts: Int = 3) async throws {
        guard let current = activeModelName else {
            throw WisprError.modelLoadFailed("No active model to reload")
        }

        var lastError: Error?
        for attempt in 0..<maxAttempts {
            do {
                unload()
                try await loadModel(current)
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
        let description = lastError?.localizedDescription ?? "Unknown error"
        throw WisprError.modelLoadFailed("Failed to reload Qwen3-ASR after \(maxAttempts) attempts: \(description)")
    }

    public func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        try await transcribe(audioSamples, language: language, onProgress: nil)
    }

    public func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage,
        onProgress: TranscriptionProgressHandler?
    ) async throws -> TranscriptionResult {
        guard let model else { throw WisprError.modelNotDownloaded }
        guard audioSamples.count >= Self.minimumSamples else {
            throw WisprError.emptyTranscription
        }

        let startTime = Date()
        let hint = Self.languageHint(for: language)
        let totalSeconds = Double(audioSamples.count) / Double(Self.sampleRate)
        var pieces: [String] = []

        for range in Self.chunkRanges(for: audioSamples) {
            try Task.checkCancellation()
            let raw = model.transcribe(
                audio: Array(audioSamples[range]),
                sampleRate: Self.sampleRate,
                language: hint
            )
            let text = Self.cleanedText(raw)
            if !text.isEmpty { pieces.append(text) }
            onProgress?(ProgressUpdate(
                processedSeconds: Double(range.upperBound) / Double(Self.sampleRate),
                totalSeconds: totalSeconds,
                textTail: text.isEmpty ? nil : text
            ))
        }

        let joined = pieces.joined(separator: " ")
        guard !joined.isEmpty else { throw WisprError.emptyTranscription }

        let duration = Date().timeIntervalSince(startTime)
        Log.whisperService.debug("Qwen3ASRService — transcribed \(audioSamples.count) samples in \(duration, format: .fixed(precision: 2))s")

        return TranscriptionResult(text: joined, detectedLanguage: hint, duration: duration)
    }

    public func supportsEndOfUtteranceDetection() async -> Bool {
        false
    }

    public func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)

        let task = Task {
            do {
                var allSamples: [Float] = []
                for await chunk in audioStream {
                    try Task.checkCancellation()
                    allSamples.append(contentsOf: chunk)
                }
                try Task.checkCancellation()
                let result = try await self.transcribe(allSamples, language: language)
                continuation.yield(result)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}
