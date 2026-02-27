//
//  PermissionStatus.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Status of a system permission
enum PermissionStatus: Sendable, Equatable {
    case notDetermined
    case denied
    case authorized
}
