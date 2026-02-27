//
//  RecordingSession.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Represents a single recording session from hotkey press to release
struct RecordingSession: Sendable {
    let id: UUID
    let startTime: Date
    let deviceUID: String
    var audioData: Data?
}
