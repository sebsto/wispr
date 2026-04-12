//
//  CorrectionStyle.swift
//  wispr
//
//  Correction style for AI text correction.
//

import Foundation

enum CorrectionStyle: String, Codable, Sendable, CaseIterable {
    case minimal
    case fullRephrase

    var displayName: String {
        switch self {
        case .minimal: "Minimal"
        case .fullRephrase: "Full Rephrase"
        }
    }
}
