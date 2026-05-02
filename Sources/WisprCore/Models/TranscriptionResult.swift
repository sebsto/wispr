//
//  TranscriptionResult.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Result of a transcription operation
public nonisolated struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let duration: TimeInterval
    /// True when the transcription engine detected end-of-utterance.
    /// Used by StateManager to auto-stop recording in hands-free mode.
    public let isEndOfUtterance: Bool

    public init(text: String, detectedLanguage: String? = nil, duration: TimeInterval, isEndOfUtterance: Bool = false) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.duration = duration
        self.isEndOfUtterance = isEndOfUtterance
    }
}
