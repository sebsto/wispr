//
//  AppStateType.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Represents the current state of the Wisp application
enum AppStateType: Sendable, Equatable {
    case idle
    case recording
    case processing
    case error(String)
}
