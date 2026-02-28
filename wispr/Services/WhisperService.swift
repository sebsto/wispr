//
//  WhisperService.swift
//  wispr
//
//  Actor managing WhisperKit model lifecycle, downloads, and transcription.
//  Requirements: 3.1, 3.2, 7.1, 7.5, 7.6, 7.7, 7.12
//

import Foundation
import WhisperKit
import AVFoundation
import os

/// Actor managing WhisperKit model lifecycle, downloads, and transcription.
///
/// ## Privacy Guarantees (Requirements 11.1, 11.3)
///
/// - **Fully local transcription**: The `transcribe(_:language:)` method uses
///   WhisperKit's `transcribe(audioArray:decodeOptions:)` which runs the Whisper
///   model entirely on-device via CoreML. No audio data or transcription results
///   are transmitted over any network connection.
/// - **No outbound network for processing**: The only network activity in this
///   service is model *downloading* (initiated explicitly by the user). Once a
///   model is downloaded, all transcription operates fully offline.
/// - **No logging of transcribed text**: Transcription results are returned to
///   the caller and immediately discarded by this service. No transcribed text
///   is logged, cached, or persisted within WhisperService.
actor WhisperService {
    // MARK: - State
    
    /// The active WhisperKit instance
    /// Note: WhisperKit may not be Sendable, so we use nonisolated(unsafe) to suppress warnings
    /// This is safe because WhisperKit is only accessed within the actor's isolation domain
    nonisolated(unsafe) private var whisperKit: WhisperKit?
    
    /// Name of the currently active model
    private var activeModelName: String?
    
    /// Active download tracking keyed by model name
    /// Stores true when a model is being downloaded (for concurrent download prevention)
    private var downloadTasks: [String: Bool] = [:]
    
    /// Base directory for model downloads.
    /// WhisperKit / HubApi stores models under this path as:
    ///   `<downloadBase>/models/argmaxinc/whisperkit-coreml/<variant>/`
    ///
    /// Uses the app's Application Support directory, which the OS maps to:
    /// - Sandboxed: `~/Library/Containers/<bundle-id>/Data/Library/Application Support/wispr/`
    /// - Non-sandboxed (dev): `~/Library/Application Support/wispr/`
    private var modelDownloadBase: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return appSupport.appendingPathComponent("wispr", isDirectory: true)
    }
    
    /// Ensures the `modelDownloadBase` directory exists on disk.
    /// Called before any download or model-status query that needs the path.
    private func ensureModelDirectoryExists() throws {
        let base = modelDownloadBase
        if !FileManager.default.fileExists(atPath: base.path) {
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
        }
    }
    
    // MARK: - Model Management
    
    /// Returns the list of available Whisper models with their metadata.
    ///
    /// Requirement 7.1: Return hardcoded list of standard Whisper models.
    ///
    /// - Returns: Array of WhisperModelInfo with model details
    func availableModels() -> [WhisperModelInfo] {
        return [
            WhisperModelInfo(
                id: "tiny",
                displayName: "Tiny",
                sizeDescription: "~75 MB",
                qualityDescription: "Fastest, lower accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "base",
                displayName: "Base",
                sizeDescription: "~140 MB",
                qualityDescription: "Fast, moderate accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "small",
                displayName: "Small",
                sizeDescription: "~460 MB",
                qualityDescription: "Balanced speed and accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "medium",
                displayName: "Medium",
                sizeDescription: "~1.5 GB",
                qualityDescription: "Slower, high accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "large-v3",
                displayName: "Large v3",
                sizeDescription: "~3 GB",
                qualityDescription: "Slowest, highest accuracy",
                status: .notDownloaded
            )
        ]
    }
    
    /// Downloads a Whisper model with progress reporting via AsyncThrowingStream.
    ///
    /// Requirements 7.2, 7.3, 7.4: Download models with progress tracking and concurrent task management.
    ///
    /// Uses WhisperKit's static `download(variant:progressCallback:)` to get real
    /// download progress, then initialises WhisperKit from the already-downloaded
    /// folder so no redundant network request is made.
    ///
    /// - Parameter model: The model to download
    /// - Returns: An AsyncThrowingStream of DownloadProgress updates
    func downloadModel(_ model: WhisperModelInfo) -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
        
        // Requirement 7.4: Handle concurrent download tasks
        guard downloadTasks[model.id] == nil else {
            continuation.finish(throwing: WisprError.modelDownloadFailed("Model \(model.displayName) is already being downloaded"))
            return stream
        }
        
        downloadTasks[model.id] = true
        
        let totalBytes = estimatedModelSize(for: model.id)
        
        // Use Task to drive the download within the actor
        // This is the accepted pattern for AsyncStream production per the spec
        Task {
            defer {
                self.downloadTasks.removeValue(forKey: model.id)
            }
            
            do {
                // Ensure model directory exists before downloading
                try self.ensureModelDirectoryExists()
                
                Log.whisperService.debug("downloadModel — starting download for '\(model.id)'")
                
                // Yield initial 0% progress
                continuation.yield(DownloadProgress(
                    phase: .downloading,
                    fractionCompleted: 0.0,
                    bytesDownloaded: 0,
                    totalBytes: totalBytes
                ))
                
                // Step 1: Download model files with real progress via WhisperKit's static API
                let modelFolder = try await WhisperKit.download(
                    variant: model.id,
                    downloadBase: self.modelDownloadBase,
                    progressCallback: { progress in
                        let fraction = progress.fractionCompleted
                        let downloaded = Int64(Double(totalBytes) * fraction)
                        continuation.yield(DownloadProgress(
                            phase: .downloading,
                            fractionCompleted: fraction,
                            bytesDownloaded: downloaded,
                            totalBytes: totalBytes
                        ))
                    }
                )
                
                Log.whisperService.debug("downloadModel — WhisperKit.download() returned modelFolder: \(modelFolder.path)")
                
                // Signal the UI that we're now loading the model into memory
                continuation.yield(DownloadProgress(
                    phase: .loadingModel,
                    fractionCompleted: 1.0,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes
                ))
                
                // Step 2: Load the model from the already-downloaded folder (no re-download)
                let config = WhisperKitConfig(
                    modelFolder: modelFolder.path,
                    prewarm: true,
                    download: false
                )
                let kit = try await WhisperKit(config)
                
                Log.whisperService.debug("downloadModel — WhisperKit init completed for '\(model.id)'")
                
                // Step 3: Store the loaded instance — avoids redundant validation load
                self.whisperKit = kit
                self.activeModelName = model.id

                Log.whisperService.debug("downloadModel — whisperKit and activeModelName set to '\(model.id)'")

                // Step 4: Warm up the CoreML pipeline
                continuation.yield(DownloadProgress(
                    phase: .warmingUp,
                    fractionCompleted: 1.0,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes
                ))

                await self.warmupModel()

                // Yield final completion
                continuation.yield(DownloadProgress(
                    phase: .warmingUp,
                    fractionCompleted: 1.0,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes
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
    
    /// Returns the estimated size in bytes for a given model.
    private func estimatedModelSize(for modelId: String) -> Int64 {
        switch modelId {
        case "tiny":
            return 75 * 1024 * 1024
        case "base":
            return 140 * 1024 * 1024
        case "small":
            return 460 * 1024 * 1024
        case "medium":
            return 1536 * 1024 * 1024
        case "large-v3":
            return 3072 * 1024 * 1024
        default:
            return 100 * 1024 * 1024
        }
    }
    
    /// Deletes a downloaded model from disk.
    ///
    /// Requirements 7.8, 7.9, 7.10: Delete models with file system cleanup and handle active model deletion.
    ///
    /// - Parameter modelName: The name of the model to delete
    /// - Throws: WisprError.modelDeletionFailed if deletion fails
    func deleteModel(_ modelName: String) async throws {
        // Requirement 7.9: If deleting the active model, switch to another model first
        if modelName == activeModelName {
            let availableModels = self.availableModels()
            
            var downloadedModels: [WhisperModelInfo] = []
            for model in availableModels where model.id != modelName {
                let status = modelStatus(model.id)
                // Use pattern matching to avoid Swift 6 concurrency warning
                if case .downloaded = status {
                    downloadedModels.append(model)
                }
            }
            
            if let nextModel = downloadedModels.first {
                try await switchModel(to: nextModel.id)
            } else {
                // Requirement 7.10: If this is the only downloaded model, unload it
                whisperKit = nil
                activeModelName = nil
            }
        }
        
        // Requirement 7.8: Remove model files from disk
        let modelPath = try getModelPath(for: modelName)
        let fileManager = FileManager.default
        
        guard fileManager.fileExists(atPath: modelPath.path) else {
            throw WisprError.modelDeletionFailed("Model \(modelName) not found on disk")
        }
        
        do {
            try fileManager.removeItem(at: modelPath)
        } catch {
            throw WisprError.modelDeletionFailed("Failed to delete model \(modelName): \(error.localizedDescription)")
        }
    }
    
    /// Returns the file system path for a given model.
    ///
    /// HubApi stores snapshots under:
    ///   `<downloadBase>/models/argmaxinc/whisperkit-coreml/`
    /// The variant folder name is resolved by WhisperKit during download
    /// (e.g. `openai_whisper-large-v3`), so we scan for a directory
    /// whose name contains the model id.
    private func getModelPath(for modelName: String) throws -> URL {
        let repoDir = modelDownloadBase
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
        
        let fm = FileManager.default
        guard fm.fileExists(atPath: repoDir.path) else {
            throw WisprError.modelDeletionFailed("Model directory not found at \(repoDir.path)")
        }
        
        // Find the variant folder that contains the model name
        let contents = try fm.contentsOfDirectory(atPath: repoDir.path)
        if let match = contents.first(where: { $0.contains(modelName) }) {
            return repoDir.appendingPathComponent(match, isDirectory: true)
        }
        
        throw WisprError.modelDeletionFailed("Model \(modelName) not found on disk")
    }
    
    /// Loads a Whisper model into memory.
    ///
    /// Requirement 7.6: Load a downloaded model and make it ready for transcription.
    ///
    /// Uses the app's `modelDownloadBase` so WhisperKit finds the previously
    /// downloaded files instead of re-downloading.
    ///
    /// - Parameter modelName: The name of the model to load
    /// - Throws: WisprError.modelLoadFailed if loading fails
    func loadModel(_ modelName: String) async throws {
        Log.whisperService.debug("loadModel — loading '\(modelName)'")
        do {
            let config = WhisperKitConfig(
                model: modelName,
                downloadBase: modelDownloadBase,
                prewarm: true
            )
            whisperKit = try await WhisperKit(config)
            activeModelName = modelName
            Log.whisperService.debug("loadModel — '\(modelName)' loaded, starting warmup")
            await warmupModel()
            Log.whisperService.debug("loadModel — '\(modelName)' loaded and warmed up successfully")
        } catch {
            throw WisprError.modelLoadFailed("Failed to load model \(modelName): \(error.localizedDescription)")
        }
    }
    
    /// Switches to a different downloaded model.
    ///
    /// Requirement 7.6: Allow switching between downloaded models.
    func switchModel(to modelName: String) async throws {
        whisperKit = nil
        activeModelName = nil
        try await loadModel(modelName)
    }
    
    /// Validates the integrity of a downloaded model by checking that its
    /// directory exists and contains at least one file.
    ///
    /// Requirement 7.5: Validate model file integrity after download.
    ///
    /// Note: We intentionally avoid creating a WhisperKit instance here.
    /// Loading a model is expensive and was the root cause of the previous
    /// "WisprError 6 / modelValidationFailed" bug — the second WhisperKit
    /// init conflicted with the first one created during download.
    func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        do {
            let modelPath = try getModelPath(for: modelName)
            let fileManager = FileManager.default
            
            guard fileManager.fileExists(atPath: modelPath.path) else {
                return false
            }
            
            // Verify the directory is not empty (contains model files)
            let contents = try fileManager.contentsOfDirectory(atPath: modelPath.path)
            return !contents.isEmpty
        } catch {
            return false
        }
    }
    
    // MARK: - Transcription
    
    /// Transcribes audio samples to text.
    ///
    /// Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 16.1, 16.2, 16.4: Perform on-device transcription
    /// with support for auto-detect, specific language, and pinned language modes.
    ///
    /// - Parameters:
    ///   - audioSamples: The audio samples to transcribe (Float array, 16kHz sample rate)
    ///   - language: The language mode for transcription
    /// - Returns: TranscriptionResult with text and metadata
    /// - Throws: WisprError.modelNotDownloaded if no model is loaded
    /// - Throws: WisprError.transcriptionFailed if transcription fails
    /// - Throws: WisprError.emptyTranscription if result is empty
    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        // Requirement 3.1: Check that a model is loaded
        guard let whisperKit = whisperKit else {
            Log.whisperService.error("transcribe — whisperKit is nil, no model loaded")
            throw WisprError.modelNotDownloaded
        }
        
        let sampleCount = audioSamples.count
        let audioDuration = Double(sampleCount) / 16000.0
        Log.whisperService.debug("transcribe — samples: \(sampleCount), duration: \(audioDuration, format: .fixed(precision: 2))s")
        
        // Guard against audio too short for meaningful transcription.
        // WhisperKit needs at least ~0.5s of audio to produce results.
        guard audioSamples.count >= 8000 else {
            Log.whisperService.debug("transcribe — audio too short (\(audioSamples.count) samples), skipping")
            throw WisprError.emptyTranscription
        }
        
        let startTime = Date()
        
        do {
            // Configure language parameter based on mode
            var languageCode: String? = nil
            
            // Requirement 16.2: Auto-detect mode
            // Requirement 16.4: Specific and pinned language modes
            switch language {
            case .autoDetect:
                languageCode = nil  // Let WhisperKit auto-detect
            case .specific(let code), .pinned(let code):
                languageCode = code
            }

            
            // Perform transcription (Requirements 3.1, 3.2)
            // When language is nil (auto-detect), enable detectLanguage so
            // WhisperKit runs its language identification pass instead of
            // falling back to the default "en".
            let results = try await whisperKit.transcribe(
                audioArray: audioSamples,
                decodeOptions: DecodingOptions(
                    language: languageCode,
                    detectLanguage: languageCode == nil
                )
            )
            
            Log.whisperService.debug("transcribe — WhisperKit returned \(results.count) segment(s)")
            #if DEBUG
            for (i, segment) in results.enumerated() {
                Log.whisperService.debug("transcribe — segment[\(i)]: \"\(segment.text, privacy: .private)\"")
            }
            #endif
            
            // Extract transcribed text from all segments
            guard !results.isEmpty else {
                throw WisprError.emptyTranscription
            }
            
            let transcribedText = results
                .map { $0.text }
                .joined()
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Filter out WhisperKit hallucination tokens (e.g. "[BLANK_AUDIO]")
            let hallucinationPatterns = ["[BLANK_AUDIO]", "(BLANK_AUDIO)", "[BLANK AUDIO]"]
            let filteredText = hallucinationPatterns.reduce(transcribedText) { text, pattern in
                text.replacingOccurrences(of: pattern, with: "")
            }.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            #if DEBUG
            if filteredText != transcribedText {
                Log.whisperService.debug("transcribe — filtered hallucinations: \"\(transcribedText, privacy: .private)\" → \"\(filteredText, privacy: .private)\"")
            }
            #endif
            
            // Requirement 3.4: Handle empty transcription
            if filteredText.isEmpty {
                throw WisprError.emptyTranscription
            }
            
            // Extract detected language (for auto-detect mode)
            // WhisperKit returns language in the first result
            let detectedLanguage = results.first?.language
            
            // Calculate duration
            let duration = Date().timeIntervalSince(startTime)
            
            #if DEBUG
            let preview = String(filteredText.prefix(50))
            Log.whisperService.debug("transcribe — result: \"\(preview, privacy: .private)\" (len=\(filteredText.count), \(duration, format: .fixed(precision: 2))s)")
            #endif
            
            // Requirement 3.3: Return TranscriptionResult
            return TranscriptionResult(
                text: filteredText,
                detectedLanguage: detectedLanguage,
                duration: duration
            )
        } catch let error as WisprError {
            Log.whisperService.error("transcribe — error: \(error.localizedDescription)")
            throw error
        } catch {
            Log.whisperService.error("transcribe — error: \(error.localizedDescription)")
            // Requirement 3.5: Handle transcription failures
            throw WisprError.transcriptionFailed("Transcription failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Error Recovery
    
    /// Attempts to reload the active model with exponential backoff retry.
    ///
    /// Requirement 12.2: If the WhisperService encounters a model loading error,
    /// attempt to reload the model before reporting failure.
    ///
    /// Uses exponential backoff: 1s, 2s, 4s, etc. between attempts.
    /// If all retries fail, the service transitions to a degraded state
    /// (whisperKit set to nil) and surfaces the last error.
    ///
    /// - Parameter maxAttempts: Maximum number of reload attempts (default 3).
    /// - Throws: WisprError.modelLoadFailed if all retry attempts are exhausted.
    func reloadModelWithRetry(maxAttempts: Int = 3) async throws {
        guard let modelName = activeModelName else {
            throw WisprError.modelLoadFailed("No active model to reload")
        }
        
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                whisperKit = nil
                let config = WhisperKitConfig(
                    model: modelName,
                    downloadBase: modelDownloadBase,
                    prewarm: true
                )
                whisperKit = try await WhisperKit(config)
                // Reload succeeded
                return
            } catch {
                lastError = error
                
                // Exponential backoff: 1s, 2s, 4s, ...
                try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
            }
        }
        
        // All retries exhausted — enter degraded state
        whisperKit = nil
        let description = lastError?.localizedDescription ?? "Unknown error"
        throw WisprError.modelLoadFailed(
            "Failed to reload model \(modelName) after \(maxAttempts) attempts: \(description)"
        )
    }
    
    // MARK: - Warmup

    /// Runs a short silent transcription to force CoreML Neural Engine pipeline compilation.
    ///
    /// The first real inference through CoreML can be slow or fail because the model
    /// hasn't been compiled/cached yet. Transcribing ~1 second of silence triggers
    /// this compilation so subsequent transcriptions work immediately.
    private func warmupModel() async {
        guard let whisperKit else { return }
        Log.whisperService.debug("warmupModel — starting warmup transcription")
        do {
            let silence = [Float](repeating: 0, count: 16000)
            _ = try await whisperKit.transcribe(audioArray: silence)
            Log.whisperService.debug("warmupModel — warmup completed successfully")
        } catch {
            // Expected — silent audio often produces empty/hallucination results.
            // The point is to trigger CoreML compilation, not get useful output.
            Log.whisperService.debug("warmupModel — warmup finished (ignored error: \(error.localizedDescription))")
        }
    }

    // MARK: - Queries
    
    /// Returns the status of a specific model.
    ///
    /// Requirement 7.7: Query model status (not downloaded, downloading, downloaded, active).
    func modelStatus(_ modelName: String) -> ModelStatus {
        if downloadTasks[modelName] != nil {
            Log.whisperService.debug("modelStatus('\(modelName)') → .downloading")
            return .downloading(progress: 0.0)
        }
        
        // Check that model files actually exist on disk before reporting
        // .active or .downloaded. This prevents stale UserDefaults state
        // (e.g. activeModelName still set after model directory was deleted)
        // from incorrectly showing a model as available.
        do {
            let modelPath = try getModelPath(for: modelName)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                if modelName == activeModelName {
                    Log.whisperService.debug("modelStatus('\(modelName)') → .active")
                    return .active
                }
                Log.whisperService.debug("modelStatus('\(modelName)') → .downloaded")
                return .downloaded
            }
        } catch {
            // Model directory not found — fall through to .notDownloaded
        }
        
        // If we thought this model was active but its files are gone,
        // clear the stale reference so the app doesn't keep assuming
        // a model is loaded.
        if modelName == activeModelName {
            Log.whisperService.warning("modelStatus('\(modelName)') — files missing, clearing stale active model")
            activeModelName = nil
            whisperKit = nil
        }
        
        Log.whisperService.debug("modelStatus('\(modelName)') → .notDownloaded")
        return .notDownloaded
    }
    
    /// Returns the name of the currently active model.
    ///
    /// Requirement 7.7: Query which model is currently active.
    func activeModel() -> String? {
        return activeModelName
    }
}
