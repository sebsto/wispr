//
//  ModelInfo.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// The ASR engine that provides a model.
public nonisolated enum ModelProvider: String, Sendable, Equatable, Hashable, CaseIterable {
    case whisper = "OpenAI Whisper"
    case nvidiaParakeet = "NVIDIA Parakeet"
}

/// Information about a transcription model
public nonisolated struct ModelInfo: Identifiable, Sendable, Equatable {
    public let id: String              // e.g. "tiny"
    public let displayName: String     // e.g. "Tiny"
    public let sizeDescription: String // e.g. "~75 MB"
    public let qualityDescription: String // e.g. "Fastest, lower accuracy"
    public let estimatedSize: Int64    // bytes, used for download progress
    public var status: ModelStatus

    /// The provider that owns this model, derived from the model ID.
    public var provider: ModelProvider {
        id.hasPrefix("parakeet") ? .nvidiaParakeet : .whisper
    }

    public init(id: String, displayName: String, sizeDescription: String, qualityDescription: String, estimatedSize: Int64, status: ModelStatus) {
        self.id = id
        self.displayName = displayName
        self.sizeDescription = sizeDescription
        self.qualityDescription = qualityDescription
        self.estimatedSize = estimatedSize
        self.status = status
    }

    // MARK: - Known Model IDs

    public enum KnownID {
        // Whisper
        public static let tiny = "tiny"
        public static let base = "base"
        public static let small = "small"
        public static let medium = "medium"
        public static let largeV3 = "large-v3"
        // Parakeet
        public static let parakeetV3 = "parakeet-v3"
        public static let parakeetEou = "parakeet-eou-160ms"
    }
}
