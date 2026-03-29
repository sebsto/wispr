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
    private let defaults: UserDefaults
    private var activeModelName: String?
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    // MARK: - V3 Constants
    private static let expectedFileCount = 23

    // MARK: - EOU Constants
    private static let eouExpectedFileCount = 21
    private static let eouDownloadedKey = "parakeetEouDownloaded"


    // MARK: - UserDefaults Flags
    private var isDownloaded: Bool {
        didSet { defaults.set(isDownloaded, forKey: Self.downloadedKey) }
    }

    private var isEouDownloaded: Bool {
        didSet { defaults.set(isEouDownloaded, forKey: Self.eouDownloadedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isDownloaded = defaults.bool(forKey: Self.downloadedKey)
        self.isEouDownloaded = defaults.bool(forKey: Self.eouDownloadedKey)
    }

    // MARK: - Internal helpers

    private func countFiles(in directory: URL) -> Int {
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
        let sdkLeaf = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
        let models = try await AsrModels.downloadAndLoad(to: ModelPaths.parakeetV3(sdkLeafName: sdkLeaf), version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.initialize(models: models)
        self.asrManager = manager
        self.isDownloaded = true
        Log.whisperService.debug("ParakeetService — V3 downloadAndLoad completed")
    }

    private func unload() async {
        await asrManager?.cleanup()
        asrManager = nil
        if activeModelName == ModelInfo.KnownID.parakeetV3 { activeModelName = nil }
        Log.whisperService.debug("ParakeetService — V3 model unloaded")
    }

    // MARK: - EOU Helpers


    private func downloadAndLoadEou() async throws {
        let cacheDir = ModelPaths.parakeetEou
        let cachedFileCount = countFiles(in: cacheDir)

        // Only download if the cache is incomplete
        if cachedFileCount < Self.eouExpectedFileCount {
            try await DownloadUtils.downloadRepo(.parakeetEou160, to: ModelPaths.parakeetEouParent)
        }
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let manager = StreamingEouAsrManager(
            configuration: config,
            chunkSize: .ms160,
            eouDebounceMs: 800 // ms of silence before generating an end of utterance
        )
        try await manager.loadModels(modelDir: cacheDir)
        self.eouManager = manager
        self.isEouDownloaded = true
        Log.whisperService.debug("ParakeetService — EOU downloadAndLoad completed")
    }

    private func unloadEou() {
        eouManager = nil
        if activeModelName == ModelInfo.KnownID.parakeetEou { activeModelName = nil }
        Log.whisperService.debug("ParakeetService — EOU model unloaded")
    }

    // MARK: - Audio Helpers

    private nonisolated func createPCMBuffer(from samples: [Float], sampleRate: Double) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw WisprError.audioRecordingFailed("Failed to create audio format for sample rate \(sampleRate)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw WisprError.audioRecordingFailed("Failed to create PCM buffer with capacity \(samples.count)")
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData else {
            throw WisprError.audioRecordingFailed("PCM buffer has no float channel data")
        }
        samples.withUnsafeBufferPointer { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            channelData[0].update(from: baseAddress, count: samples.count)
        }
        return buffer
    }

    // MARK: - EOU Transcription

    private func transcribeWithEou(_ audioSamples: [Float]) async throws -> TranscriptionResult {
        guard let manager = eouManager else { throw WisprError.modelNotDownloaded }
        guard audioSamples.count >= 8000 else { throw WisprError.emptyTranscription }

        await manager.reset()
        let startTime = Date()
        let buffer = try createPCMBuffer(from: audioSamples, sampleRate: 16000)
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
                var eouDetected = false
                for await chunk in audioStream {
                    try Task.checkCancellation()
                    let buffer = try createPCMBuffer(from: chunk, sampleRate: 16000)
                    _ = try await manager.process(audioBuffer: buffer)
                    if await manager.eouDetected {
                        eouDetected = true
                        break
                    }
                }
                let finalText = try await manager.finish()
                let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
                // Always yield when EOU was detected, even if text is empty,
                // so StateManager can auto-stop recording and reset to idle.
                if eouDetected || !trimmed.isEmpty {
                    continuation.yield(TranscriptionResult(
                        text: trimmed,
                        detectedLanguage: nil,
                        duration: Date().timeIntervalSince(startTime),
                        isEndOfUtterance: eouDetected
                    ))
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
                id: ModelInfo.KnownID.parakeetV3,
                displayName: "Parakeet V3",
                sizeDescription: "~400 MB",
                qualityDescription: "Fast, high accuracy, multilingual (25 languages)",
                estimatedSize: 400 * 1024 * 1024,
                status: .notDownloaded
            ),
            ModelInfo(
                id: ModelInfo.KnownID.parakeetEou,
                displayName: "Realtime 120M",
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

        let isEou = model.id == ModelInfo.KnownID.parakeetEou
        let estimatedSize = model.estimatedSize
        let expectedFileCount = isEou ? Self.eouExpectedFileCount : Self.expectedFileCount
        let cacheDir: URL
        if isEou {
            cacheDir = ModelPaths.parakeetEou
        } else {
            let sdkLeaf = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
            cacheDir = ModelPaths.parakeetV3(sdkLeafName: sdkLeaf)
        }

        let task = Task {
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
                        let count = countFiles(in: cacheDir)
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

        downloadTasks[model.id] = task

        return stream
    }

    func deleteModel(_ modelName: String) async throws {
        downloadTasks[modelName]?.cancel()
        downloadTasks.removeValue(forKey: modelName)

        if modelName == ModelInfo.KnownID.parakeetEou {
            unloadEou()
            let cacheDir = ModelPaths.parakeetEou
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
            await unload()
            let sdkLeaf = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
            let cacheDir = ModelPaths.parakeetV3(sdkLeafName: sdkLeaf)
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
            if modelName == ModelInfo.KnownID.parakeetEou {
                try await downloadAndLoadEou()
            } else {
                try await downloadAndLoad()
            }
            activeModelName = modelName
        } catch {
            let displayName = modelName == ModelInfo.KnownID.parakeetEou ? "Parakeet EOU" : "Parakeet V3"
            throw WisprError.modelLoadFailed("Failed to load \(displayName): \(error.localizedDescription)")
        }
    }

    func switchModel(to modelName: String) async throws {
        if modelName == ModelInfo.KnownID.parakeetEou {
            await unload()
        } else {
            unloadEou()
        }
        try await loadModel(modelName)
    }

    func unloadCurrentModel() async {
        await unload()
        unloadEou()
    }

    func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        if modelName == ModelInfo.KnownID.parakeetEou {
            return eouManager != nil || isEouDownloaded
        }
        return asrManager != nil || isDownloaded
    }

    func modelStatus(_ modelName: String) async -> ModelStatus {
        if downloadTasks[modelName] != nil {
            return .downloading(progress: 0.0)
        }

        // Check actual files on disk rather than relying solely on
        // UserDefaults flags, which can get out of sync (e.g. model
        // downloaded but flag not yet set, or flag cleared).
        if modelName == ModelInfo.KnownID.parakeetEou {
            let filesExist = countFiles(in: ModelPaths.parakeetEou) >= Self.eouExpectedFileCount
            if filesExist {
                if modelName == activeModelName, eouManager != nil {
                    return .active
                }
                return .downloaded
            }
        } else {
            let sdkLeaf = AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent
            let v3Dir = ModelPaths.parakeetV3(sdkLeafName: sdkLeaf)
            let filesExist = countFiles(in: v3Dir) >= Self.expectedFileCount
            if filesExist {
                if modelName == activeModelName, asrManager != nil {
                    return .active
                }
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
        let isEou = currentModel == ModelInfo.KnownID.parakeetEou

        for attempt in 0..<maxAttempts {
            do {
                if isEou {
                    unloadEou()
                    try await downloadAndLoadEou()
                } else {
                    await unload()
                    try await downloadAndLoad()
                }
                activeModelName = currentModel
                return
            } catch {
                lastError = error
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }

        if isEou { unloadEou() } else { await unload() }
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
        if activeModelName == ModelInfo.KnownID.parakeetEou {
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

    func supportsEndOfUtteranceDetection() async -> Bool {
        return activeModelName == ModelInfo.KnownID.parakeetEou && eouManager != nil
    }

    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        if activeModelName == ModelInfo.KnownID.parakeetEou {
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
