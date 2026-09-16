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
    /// True when this is an intermediate ("ghost text") result emitted during
    /// streaming, rather than a final transcription. Partial results are shown
    /// live in the recording overlay and are superseded by later yields.
    public let isPartial: Bool

    public init(text: String, detectedLanguage: String? = nil, duration: TimeInterval, isEndOfUtterance: Bool = false, isPartial: Bool = false) {
        self.text = text
        self.detectedLanguage = detectedLanguage
        self.duration = duration
        self.isEndOfUtterance = isEndOfUtterance
        self.isPartial = isPartial
    }
}
