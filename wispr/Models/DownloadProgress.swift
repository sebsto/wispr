//
//  DownloadProgress.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Progress information for model downloads
struct DownloadProgress: Sendable {
    /// Current phase of the download lifecycle.
    enum Phase: Sendable {
        /// Downloading model files from the network.
        case downloading
        /// Download finished; loading model into memory (CoreML compile, etc.).
        case loadingModel
        /// Model loaded; running a warmup transcription to compile the CoreML pipeline.
        case warmingUp
    }

    let phase: Phase
    let fractionCompleted: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
}
