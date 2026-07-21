//
//  TranscriptionEngine.swift
//  wispr
//
//  Protocol abstracting the speech-to-text engine so the app
//  is decoupled from any specific ASR backend (WhisperKit, FluidAudio, etc.).
//

import Foundation

/// Abstract interface for any on-device speech-to-text engine.
///
/// Conforming types must be actors to guarantee thread-safe access
/// to model state and transcription resources.
public protocol TranscriptionEngine: Actor {

    // MARK: - Model Management

    /// Returns the list of models this engine supports.
    func availableModels() async -> [ModelInfo]

    /// Downloads a model with progress reporting.
    func downloadModel(_ model: ModelInfo) async -> AsyncThrowingStream<DownloadProgress, Error>

    /// Deletes a downloaded model from disk.
    func deleteModel(_ modelName: String) async throws

    /// Loads a downloaded model into memory, making it ready for transcription.
    func loadModel(_ modelName: String) async throws

    /// Unloads the current model and loads a different one.
    func switchModel(to modelName: String) async throws

    /// Unloads the currently loaded model from memory without deleting its files.
    func unloadCurrentModel() async

    /// Checks whether a downloaded model's files are intact.
    func validateModelIntegrity(_ modelName: String) async throws -> Bool

    /// Returns the current status of a model (not downloaded, downloading, downloaded, active).
    func modelStatus(_ modelName: String) async -> ModelStatus

    /// Returns the name of the currently loaded model, or nil if none is loaded.
    func activeModel() async -> String?

    /// Attempts to reload the active model with exponential backoff retry.
    func reloadModelWithRetry(maxAttempts: Int) async throws

    // MARK: - Batch Transcription

    /// Transcribes a complete audio buffer to text.
    func transcribe(
        _ audioSamples: [Float],
        language: TranscriptionLanguage
    ) async throws -> TranscriptionResult

    // MARK: - Streaming Transcription

    /// Accepts a stream of audio chunks and yields partial transcription results
    /// as they become available.
    ///
    /// Engines that don't support true streaming should accumulate all chunks
    /// and yield a single final result when the input stream finishes.
    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage,
        emitPartialResults: Bool
    ) async -> AsyncThrowingStream<TranscriptionResult, Error>

    /// Whether the currently loaded model supports end-of-utterance detection.
    /// When true, transcribeStream() will finish its output when the user
    /// stops speaking. When false, transcribeStream() only finishes when
    /// the input audio stream ends.
    func supportsEndOfUtteranceDetection() async -> Bool

    /// Whether the currently loaded model supports real-time partial
    /// transcription results. When true and `emitPartialResults` is passed to
    /// transcribeStream(), the engine yields intermediate `isPartial` results
    /// during processing.
    func supportsPartialResults() async -> Bool
}

// MARK: - Default Parameter Convenience

extension TranscriptionEngine {
    /// Convenience overload with default retry count.
    public func reloadModelWithRetry() async throws {
        try await reloadModelWithRetry(maxAttempts: 3)
    }

    /// Default implementation so adding this requirement is not source-breaking
    /// for existing conformers. Engines that support partial results override
    /// this; most (e.g. WhisperService) get the correct `false` default.
    public func supportsPartialResults() async -> Bool {
        false
    }

    /// Two-argument convenience overload that preserves existing call sites.
    /// Swift protocol *requirements* cannot carry default argument values, so
    /// the default lives here in the extension. This forwards to the
    /// three-argument requirement above; the differing arity means it
    /// dispatches to the conforming type's implementation, not to itself
    /// (no recursion).
    public func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        await transcribeStream(audioStream, language: language, emitPartialResults: false)
    }
}
