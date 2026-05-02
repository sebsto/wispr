//
//  DownloadProgress.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Progress information for model downloads
public nonisolated struct DownloadProgress: Sendable {
    /// Current phase of the download lifecycle.
    public enum Phase: Sendable {
        /// Downloading model files from the network.
        case downloading
        /// Download finished; loading model into memory (CoreML compile, etc.).
        case loadingModel
        /// Model loaded; running a warmup transcription to compile the CoreML pipeline.
        case warmingUp
    }

    public let phase: Phase
    public let fractionCompleted: Double
    public let bytesDownloaded: Int64
    public let totalBytes: Int64

    public init(phase: Phase, fractionCompleted: Double, bytesDownloaded: Int64, totalBytes: Int64) {
        self.phase = phase
        self.fractionCompleted = fractionCompleted
        self.bytesDownloaded = bytesDownloaded
        self.totalBytes = totalBytes
    }
}
