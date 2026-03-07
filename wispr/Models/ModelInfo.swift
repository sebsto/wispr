//
//  ModelInfo.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Information about a transcription model
struct ModelInfo: Identifiable, Sendable, Equatable {
    let id: String              // e.g. "tiny"
    let displayName: String     // e.g. "Tiny"
    let sizeDescription: String // e.g. "~75 MB"
    let qualityDescription: String // e.g. "Fastest, lower accuracy"
    let estimatedSize: Int64    // bytes, used for download progress
    var status: ModelStatus

    // MARK: - Known Model IDs

    enum KnownID {
        // Whisper
        nonisolated static let tiny = "tiny"
        nonisolated static let base = "base"
        nonisolated static let small = "small"
        nonisolated static let medium = "medium"
        nonisolated static let largeV3 = "large-v3"
        // Parakeet
        nonisolated static let parakeetV3 = "parakeet-v3"
        nonisolated static let parakeetEou = "parakeet-eou-160ms"
    }
}
