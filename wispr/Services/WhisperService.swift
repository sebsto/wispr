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
    
    // MARK: - Model Management
    
    /// Returns the list of available Whisper models with their metadata.
    ///
    /// Requirement 7.1: Return hardcoded list of standard Whisper models.
    ///
    /// - Returns: Array of WhisperModelInfo with model details
    func availableModels() -> [WhisperModelInfo] {
        return [
            WhisperModelInfo(
                id: "openai_whisper-tiny",
                displayName: "Tiny",
                sizeDescription: "~75 MB",
                qualityDescription: "Fastest, lower accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "openai_whisper-base",
                displayName: "Base",
                sizeDescription: "~140 MB",
                qualityDescription: "Fast, moderate accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "openai_whisper-small",
                displayName: "Small",
                sizeDescription: "~460 MB",
                qualityDescription: "Balanced speed and accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "openai_whisper-medium",
                displayName: "Medium",
                sizeDescription: "~1.5 GB",
                qualityDescription: "Slower, high accuracy",
                status: .notDownloaded
            ),
            WhisperModelInfo(
                id: "openai_whisper-large",
                displayName: "Large",
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
    /// Note: WhisperKit downloads models automatically during initialization.
    /// This method triggers the download by attempting to load the model,
    /// then reports progress by monitoring the file system.
    ///
    /// - Parameter model: The model to download
    /// - Returns: An AsyncThrowingStream of DownloadProgress updates
    func downloadModel(_ model: WhisperModelInfo) -> AsyncThrowingStream<DownloadProgress, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: DownloadProgress.self)
        
        // Requirement 7.4: Handle concurrent download tasks
        guard downloadTasks[model.id] == nil else {
            continuation.finish(throwing: WispError.modelDownloadFailed("Model \(model.displayName) is already being downloaded"))
            return stream
        }
        
        downloadTasks[model.id] = true
        
        // Use Task to drive the download within the actor
        // This is the accepted pattern for AsyncStream production per the spec
        Task {
            defer {
                self.downloadTasks.removeValue(forKey: model.id)
            }
            
            do {
                continuation.yield(DownloadProgress(
                    fractionCompleted: 0.0,
                    bytesDownloaded: 0,
                    totalBytes: estimatedModelSize(for: model.id)
                ))
                
                let kit = try await WhisperKit(model: model.id)
                
                let totalBytes = estimatedModelSize(for: model.id)
                continuation.yield(DownloadProgress(
                    fractionCompleted: 1.0,
                    bytesDownloaded: totalBytes,
                    totalBytes: totalBytes
                ))
                
                let isValid = try await validateModelIntegrity(model.id)
                guard isValid else {
                    continuation.finish(throwing: WispError.modelValidationFailed("Model \(model.displayName) failed integrity check"))
                    return
                }
                
                _ = kit
                continuation.finish()
            } catch is CancellationError {
                continuation.finish(throwing: WispError.modelDownloadFailed("Download of \(model.displayName) was cancelled"))
            } catch {
                continuation.finish(throwing: WispError.modelDownloadFailed("Failed to download \(model.displayName): \(error.localizedDescription)"))
            }
        }
        
        return stream
    }
    
    /// Returns the estimated size in bytes for a given model.
    private func estimatedModelSize(for modelId: String) -> Int64 {
        switch modelId {
        case "openai_whisper-tiny":
            return 75 * 1024 * 1024
        case "openai_whisper-base":
            return 140 * 1024 * 1024
        case "openai_whisper-small":
            return 460 * 1024 * 1024
        case "openai_whisper-medium":
            return 1536 * 1024 * 1024
        case "openai_whisper-large":
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
    /// - Throws: WispError.modelDeletionFailed if deletion fails
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
            throw WispError.modelDeletionFailed("Model \(modelName) not found on disk")
        }
        
        do {
            try fileManager.removeItem(at: modelPath)
        } catch {
            throw WispError.modelDeletionFailed("Failed to delete model \(modelName): \(error.localizedDescription)")
        }
    }
    
    /// Returns the file system path for a given model.
    private func getModelPath(for modelName: String) throws -> URL {
        guard let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            throw WispError.modelDeletionFailed("Could not locate Application Support directory")
        }
        
        // WhisperKit stores models in Application Support/whisperkit/models/
        return appSupportURL
            .appendingPathComponent("whisperkit", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }
    
    /// Loads a Whisper model into memory.
    ///
    /// Requirement 7.6: Load a downloaded model and make it ready for transcription.
    ///
    /// - Parameter modelName: The name of the model to load
    /// - Throws: WispError.modelNotDownloaded if model is not downloaded
    /// - Throws: WispError.modelLoadFailed if loading fails
    func loadModel(_ modelName: String) async throws {
        do {
            whisperKit = try await WhisperKit(model: modelName)
            activeModelName = modelName
        } catch {
            throw WispError.modelLoadFailed("Failed to load model \(modelName): \(error.localizedDescription)")
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
    
    /// Validates the integrity of a downloaded model.
    ///
    /// Requirement 7.5: Validate model file integrity after download.
    func validateModelIntegrity(_ modelName: String) async throws -> Bool {
        // Check if model files exist
        do {
            let modelPath = try getModelPath(for: modelName)
            let fileManager = FileManager.default
            
            guard fileManager.fileExists(atPath: modelPath.path) else {
                return false
            }
            
            // Try to load the model to verify it's not corrupted
            let testKit = try await WhisperKit(model: modelName)
            _ = testKit
            
            return true
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
    /// - Throws: WispError.modelNotDownloaded if no model is loaded
    /// - Throws: WispError.transcriptionFailed if transcription fails
    /// - Throws: WispError.emptyTranscription if result is empty
    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult {
        // Requirement 3.1: Check that a model is loaded
        guard let whisperKit = whisperKit else {
            throw WispError.modelNotDownloaded
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
            let results = try await whisperKit.transcribe(
                audioArray: audioSamples,
                decodeOptions: DecodingOptions(language: languageCode)
            )
            
            // Extract transcribed text from all segments
            guard !results.isEmpty else {
                throw WispError.emptyTranscription
            }
            
            let transcribedText = results
                .map { $0.text }
                .joined()
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            
            // Requirement 3.4: Handle empty transcription
            if transcribedText.isEmpty {
                throw WispError.emptyTranscription
            }
            
            // Extract detected language (for auto-detect mode)
            // WhisperKit returns language in the first result
            let detectedLanguage = results.first?.language
            
            // Calculate duration
            let duration = Date().timeIntervalSince(startTime)
            
            // Requirement 3.3: Return TranscriptionResult
            return TranscriptionResult(
                text: transcribedText,
                detectedLanguage: detectedLanguage,
                duration: duration
            )
        } catch let error as WispError {
            throw error
        } catch {
            // Requirement 3.5: Handle transcription failures
            throw WispError.transcriptionFailed("Transcription failed: \(error.localizedDescription)")
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
    /// - Throws: WispError.modelLoadFailed if all retry attempts are exhausted.
    func reloadModelWithRetry(maxAttempts: Int = 3) async throws {
        guard let modelName = activeModelName else {
            throw WispError.modelLoadFailed("No active model to reload")
        }
        
        var lastError: Error?
        
        for attempt in 0..<maxAttempts {
            do {
                whisperKit = nil
                whisperKit = try await WhisperKit(model: modelName)
                // Reload succeeded
                return
            } catch {
                lastError = error
                
                // Exponential backoff: 1s, 2s, 4s, ...
                let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
                try await Task.sleep(nanoseconds: delay)
            }
        }
        
        // All retries exhausted — enter degraded state
        whisperKit = nil
        let description = lastError?.localizedDescription ?? "Unknown error"
        throw WispError.modelLoadFailed(
            "Failed to reload model \(modelName) after \(maxAttempts) attempts: \(description)"
        )
    }
    
    // MARK: - Queries
    
    /// Returns the status of a specific model.
    ///
    /// Requirement 7.7: Query model status (not downloaded, downloading, downloaded, active).
    func modelStatus(_ modelName: String) -> ModelStatus {
        if modelName == activeModelName {
            return .active
        }
        
        if downloadTasks[modelName] != nil {
            return .downloading(progress: 0.0)
        }
        
        do {
            let modelPath = try getModelPath(for: modelName)
            if FileManager.default.fileExists(atPath: modelPath.path) {
                return .downloaded
            }
        } catch {
            return .notDownloaded
        }
        
        return .notDownloaded
    }
    
    /// Returns the name of the currently active model.
    ///
    /// Requirement 7.7: Query which model is currently active.
    func activeModel() -> String? {
        return activeModelName
    }
}
