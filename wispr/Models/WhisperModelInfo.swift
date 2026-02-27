//
//  WhisperModelInfo.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Information about a Whisper model
struct WhisperModelInfo: Identifiable, Sendable, Equatable {
    let id: String              // e.g. "openai_whisper-tiny"
    let displayName: String     // e.g. "Tiny"
    let sizeDescription: String // e.g. "~75 MB"
    let qualityDescription: String // e.g. "Fastest, lower accuracy"
    var status: ModelStatus
}
