//
//  AppStateType.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Represents the current state of the Wisp application
enum AppStateType: Sendable, Equatable, CustomStringConvertible {
    case idle
    case recording
    case processing
    case error(String)

    var description: String {
        switch self {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .error(let message): "error(\(message))"
        }
    }
}
