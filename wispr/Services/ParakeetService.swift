//
//  ParakeetService.swift
//  wispr
//
//  Actor encapsulating FluidAudio Parakeet model lifecycle and transcription.
//  Supports both Parakeet V3 (batch) and Parakeet EOU 120M (streaming).
//  Conforms to TranscriptionEngine so it can be used interchangeably with WhisperService.
//

import AVFoundation
import CoreML
import Foundation
import FluidAudio
import os

actor ParakeetService {
    // MARK: - V3 State
    nonisolated static let downloadedKey = "parakeetV3Downloaded"
    nonisolated(unsafe) private var asrManager: AsrManager?

    // MARK: - EOU State
    nonisolated(unsafe) private var eouManager: StreamingEouAsrManager?

    // MARK: - Shared State
    private var activeModelName: String?
    private var downloadTasks: [String: Bool] = [:]

    // MARK: - V3 Constants
    private static let modelId = ModelInfo.KnownID.parakeetV3
    private static let expectedFileCount = 23

    // MARK: - EOU Constants
    private static let eouModelId = ModelInfo.KnownID.parakeetEou
    private static let eouExpectedFileCount = 21
    private static let eouDownloadedKey = "parakeetEouDownloaded"

    // MARK: - UserDefaults Flags
    private var isDownloaded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.downloadedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.downloadedKey) }
    }

    private var isEouDownloaded: Bool {
        get { UserDefaults.standard.bool(forKey: Self.eouDownloadedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.eouDownloadedKey) }
    }

    // MARK: - Internal helpers

    private static func countFiles(in directory: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        while enumerator.nextObject() != nil { count += 1 }
        return count
    }

    // MARK: - V3 Helpers

    private func downloadAndLoad() async throws {
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.isDownloaded = true
        Log.whisperService.debug("ParakeetService — V3 downloadAndLoad completed")
    }

    private func unload() {
        asrManager?.cleanup()
        asrManager = nil
        if activeModelName == Self.modelId { activeModelName = nil }
        Log.whisperService.debug("ParakeetService — V3 model unloaded")
    }

    // MARK: - EOU Helpers

    private func eouCacheDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent("160ms", isDirectory: true)
    }

    private func eouModelsParentDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    private func downloadAndLoadEou() async throws {
        let cacheDir = eouCacheDirectory()
        let cachedFileCount = Self.countFiles(in: cacheDir)

        // Only download if the cache is incomplete
        if cachedFileCount < Self.eouExpectedFileCount {
            let parentDir = eouModelsParentDirectory()
            try await DownloadUtils.downloadRepo(.parakeetEou160, to: parentDir)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let manager = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms160,
            eouDebounceMs: 1280
        )
        try await manager.loadModels(modelDir: cacheDir)
        self.eouManager = manager
        self.isEouDownloaded = true
        Log.whisperService.debug("ParakeetService — EOU downloadAndLoad completed")
    }

    private func unloadEou() {
        eouManager = nil
        if activeModelName == Self.eouModelId { activeModelName = nil }
        Log.whisperService.debug("ParakeetService — EOU model unloaded")
    }

    // MARK: - Audio Helpers

    private nonisolated static func createPCMBuffer(from samples: [Float], sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { ptr in
            buffer.floatChannelData![0].update(from: ptr.baseAddress!, count: samples.count)
        }
        return buffer
    }

    // MARK: - EOU Transcription

    private func transcribeWithEou(_ audioSamples: [Float]) async throws -> TranscriptionResult {
        guard let manager = eouManager else { throw WisprError.modelNotDownloaded }
        guard audioSamples.count >= 8000 else { throw WisprError.emptyTranscription }

        await manager.reset()
        let startTime = Date()
        let buffer = Self.createPCMBuffer(from: audioSamples, sampleRate: 16000)
        _ = try await manager.process(audioBuffer: buffer)
        let text = try await manager.finish()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WisprError.emptyTranscription }

        let duration = Date().timeIntervalSince(startTime)
        Log.whisperService.debug("ParakeetService — EOU transcribed \(audioSamples.count) samples in \(duration, format: .fixed(precision: 2))s")

        return TranscriptionResult(text: trimmed, detectedLanguage: nil, duration: duration)
    }

    private func transcribeStreamWithEou(_ audioStream: AsyncStream<[Float]>) -> AsyncThrowingStream<TranscriptionResult, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)

        let manager = self.eouManager

        let task = Task {
            guard let manager else {
                continuation.finish(throwing: WisprError.modelNotDownloaded)
                return
            }
            await manager.reset()
            let startTime = Date()
            do {
                for await chunk in audioStream {
                    try Task.checkCancellation()
                    let buffer = Self.createPCMBuffer(from: chunk, sampleRate: 16000)
                    _ = try await manager.process(audioBuffer: buffer)
                }
                let finalText = try await manager.finish()
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    continuation.yield(TranscriptionResult(text: trimmed, detectedLanguage: nil, duration: Date().timeIntervalSince(startTime)))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }

        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

// MARK: - TranscriptionEngine Conformance

extension ParakeetService: TranscriptionEngine {

    func availableModels() async -> [ModelInfo] {
        [
            ModelInfo(
                id: Self.modelId,
                displayName: "Parakeet V3",
                sizeDescription: "~400 MB",
                qualityDescription: "Fast, high accuracy, multilingual (25 languages)",
                estimatedSize: 400 * 1024 * 1024,
                status: .notDownloaded
            ),
            ModelInfo(
                id: Self.eouModelId,
                displayName: "Parakeet Realtime (120M)",
                sizeDescription: "~150 MB",
                qualityDescription: "Low-latency streaming with end-of-utterance detection (English only)",
                estimatedSize: 150 * 1024 * 1024,
                status: .notDownloaded
            )
        ]
    }

    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)

        guard downloadTasks[model.id] == nil else {
            continuation.finish(throwing: WisprError.modelDownloadFailed("Model \(model.displayName) is already being downloaded"))
            return stream
        }

        downloadTasks[model.id] = true

        let isEou = model.id == Self.eouModelId
        let estimatedSize = model.estimatedSize
        let expectedFileCount = isEou ? Self.eouExpectedFileCount : Self.expectedFileCount
        let cacheDir = isEou ? eouCacheDirectory() : AsrModels.defaultCacheDirectory(for: .v3)

        Task {
            defer { self.downloadTasks.removeValue(forKey: model.id) }

            do {
                continuation.yield(DownloadProgress(
                    phase: .downloading,
                    fractionCompleted: 0.0,
                    bytesDownloaded: 0,
                    totalBytes: estimatedSize
                ))

                // Poll cache directory for file-count progress during download
                let progressTask = Task {
                    while !Task.isCancelled {
                        try await Task.sleep(for: .milliseconds(500))
                        let count = Self.countFiles(in: cacheDir)
                        if count >= expectedFileCount {
                            continuation.yield(DownloadProgress(
                                phase: .loadingModel,
                                fractionCompleted: 1.0,
                                bytesDownloaded: estimatedSize,
                                totalBytes: estimatedSize
                            ))
                            break
                        }
                        let fraction = Double(count) / Double(expectedFileCount)
                        let downloaded = Int64(Double(estimatedSize) * fraction)
                        continuation.yield(DownloadProgress(
                            phase: .downloading,
                            fractionCompleted: fraction,
                            bytesDownloaded: downloaded,
                            totalBytes: estimatedSize
                        ))
                    }
                }
                defer { progressTask.cancel() }

                if isEou {
                    try await self.downloadAndLoadEou()
                } else {
                    try await self.downloadAndLoad()
                }
                self.activeModelName = model.id

                continuation.yield(DownloadProgress(
                    phase: .warmingUp,
                    fractionCompleted: 1.0,
                    bytesDownloaded: estimatedSize,
                    totalBytes: estimatedSize
                ))
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: WisprError.modelDownloadFailed("Download of \(model.displayName) was cancelled"))
            } catch {
                continuation.finish(throwing: WisprError.modelDownloadFailed("Failed to download \(model.displayName): \(error.localizedDescription)"))
            }
        }

        return stream
    }

    func deleteModel(_ modelName: String) async throws {
        if modelName == Self.eouModelId {
            unloadEou()
            let cacheDir = eouCacheDirectory()
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                do {
                    try FileManager.default.removeItem(at: cacheDir)
                    Log.whisperService.debug("ParakeetService — removed EOU cache at \(cacheDir.path)")
                } catch {
                    Log.whisperService.error("ParakeetService — failed to remove EOU cache: \(error.localizedDescription)")
                    throw WisprError.modelDeletionFailed("Failed to delete Parakeet EOU cache: \(error.localizedDescription)")
                }
            }
            isEouDownloaded = false
        } else {
            unload()
            let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
            if FileManager.default.fileExists(atPath: cacheDir.path) {
                do {
                    try FileManager.default.removeItem(at: cacheDir)
                    Log.whisperService.debug("ParakeetService — removed V3 cache at \(cacheDir.path)")
                } catch {
                    Log.whisperService.error("ParakeetService — failed to remove V3 cache: \(error.localizedDescription)")
                    throw WisprError.modelDeletionFailed("Failed to delete Parakeet V3 cache: \(error.localizedDescription)")
                }
            }
            isDownloaded = false
        }
        Log.whisperService.debug("ParakeetService — model \(modelName) deleted")
    }

    func loadModel(_ modelName: String) async throws {
        Log.whisperService.debug("ParakeetService — loadModel starting for \(modelName)")
        do {
            if modelName == Self.eouModelId {
                try await downloadAndLoadEou()
            } else {
                try await downloadAndLoad()
            }
            activeModelName = modelName
        } catch {
            let displayName = modelName == Self.eouModelId ? "Parakeet EOU" : "Parakeet V3"
            throw WisprError.modelLoadFailed("Failed to load \(displayName): \(error.localizedDescription)")
        }
    }

    func switchModel(to modelName: String) async throws {
        if modelName == Self.eouModelId {
            unload()
        } else {
            unloadEou()
        }
        try await loadModel(modelName)
    }

    func unloadCurrentModel() async {
        unload()
        unloadEou()
    }

    func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        if modelName == Self.eouModelId {
            return eouManager != nil || isEouDownloaded
        }
        return asrManager != nil || isDownloaded
    }

    func modelStatus(_ modelName: String) async -> ModelStatus {
        if downloadTasks[modelName] != nil {
            return .downloading(progress: 0.0)
        }
        if modelName == Self.eouModelId {
            if modelName == activeModelName, eouManager != nil {
                return .active
            }
            if isEouDownloaded {
                return .downloaded
            }
        } else {
            if modelName == activeModelName, asrManager != nil {
                return .active
            }
            if isDownloaded {
                return .downloaded
            }
        }
        return .notDownloaded
    }

    func activeModel() async -> String? {
        activeModelName
    }

    func reloadModelWithRetry(maxAttempts: Int = 3) async throws {
        guard let currentModel = activeModelName else {
            throw WisprError.modelLoadFailed("No active model to reload")
        }

        var lastError: Error?
        let isEou = currentModel == Self.eouModelId

        for attempt in 0..<maxAttempts {
            do {
                if isEou {
                    unloadEou()
                    try await downloadAndLoadEou()
                } else {
                    unload()
                    try await downloadAndLoad()
                }
                activeModelName = currentModel
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }

        if isEou { unloadEou() } else { unload() }
        let displayName = isEou ? "Parakeet EOU" : "Parakeet V3"
        let description = lastError?.localizedDescription ?? "Unknown error"
        throw WisprError.modelLoadFailed(
            "Failed to reload \(displayName) after \(maxAttempts) attempts: \(description)"
        )
    }

    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        if activeModelName == Self.eouModelId {
            return try await transcribeWithEou(audioSamples)
        }

        guard let asrManager else {
            throw WisprError.modelNotDownloaded
        }

        guard audioSamples.count >= 8000 else {
            Log.whisperService.debug("ParakeetService — audio too short (\(audioSamples.count) samples), skipping")
            throw WisprError.emptyTranscription
        }

        let startTime = Date()
        let result = try await asrManager.transcribe(audioSamples, source: .microphone)

        let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw WisprError.emptyTranscription
        }

        let duration = Date().timeIntervalSince(startTime)
        Log.whisperService.debug("ParakeetService — V3 transcribed \(audioSamples.count) samples in \(duration, format: .fixed(precision: 2))s")

        return TranscriptionResult(
            text: text,
            detectedLanguage: nil,
            duration: duration
        )
    }

    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        if activeModelName == Self.eouModelId {
            return transcribeStreamWithEou(audioStream)
        }

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

        continuation.onTermination = { _ in
            task.cancel()
        }

        return stream
    }
}
