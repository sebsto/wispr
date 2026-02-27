//
//  TranscriptionResult.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Result of a transcription operation
struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
}
