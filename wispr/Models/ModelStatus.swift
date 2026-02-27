//
//  ModelStatus.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Status of a Whisper model
enum ModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(progress: Double)
    case downloaded
    case active
}
