//
//  TranscriptionLanguage.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Language mode for transcription
enum TranscriptionLanguage: Sendable, Codable, Equatable {
    case autoDetect
    case specific(code: String)
    case pinned(code: String)
    
    var isAutoDetect: Bool {
        if case .autoDetect = self { return true }
        return false
    }
    
    var isPinned: Bool {
        if case .pinned = self { return true }
        return false
    }
    
    var languageCode: String? {
        switch self {
        case .autoDetect: return nil
        case .specific(let code), .pinned(let code): return code
        }
    }
}
