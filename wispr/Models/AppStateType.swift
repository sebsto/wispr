//
//  AppStateType.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Represents the current state of the Wispr application
enum AppStateType: Sendable, Equatable, CustomStringConvertible {
    case loading(String)  // Loading/warming up model at startup
    case idle
    case recording
    case processing
    case error(String)

    var description: String {
        switch self {
        case .loading(let message): "loading(\(message))"
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .error(let message): "error(\(message))"
        }
    }
}
