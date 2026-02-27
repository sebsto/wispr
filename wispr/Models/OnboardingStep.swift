//
//  OnboardingStep.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Steps in the onboarding flow
enum OnboardingStep: Int, Sendable, CaseIterable {
    case welcome = 0
    case microphonePermission = 1
    case accessibilityPermission = 2
    case modelSelection = 3
    case testDictation = 4
    case completion = 5
    
    var isSkippable: Bool {
        self == .testDictation
    }
    
    var isRequired: Bool {
        switch self {
        case .microphonePermission, .accessibilityPermission, .modelSelection:
            return true
        default:
            return false
        }
    }
}
