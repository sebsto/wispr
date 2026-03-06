//
//  ModelInfo.swift
//  wispr
//
//  Created by Kiro
//

import Foundation
import SwiftUI

/// The ASR engine that provides a model.
enum ModelProvider: String, Sendable, Equatable, Hashable, CaseIterable {
    case whisper = "OpenAI Whisper"
    case nvidiaParakeet = "NVIDIA Parakeet"

    var icon: String {
        switch self {
        case .whisper: "waveform"
        case .nvidiaParakeet: "bird"
        }
    }

    var tintColor: Color {
        switch self {
        case .whisper: .blue
        case .nvidiaParakeet: .green
        }
    }
}

/// Information about a transcription model
struct ModelInfo: Identifiable, Sendable, Equatable {
    let id: String
    let displayName: String
    let provider: ModelProvider
    let sizeDescription: String
    let qualityDescription: String
    var status: ModelStatus

    nonisolated init(
        id: String,
        displayName: String,
        provider: ModelProvider,
        sizeDescription: String,
        qualityDescription: String,
        status: ModelStatus
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.sizeDescription = sizeDescription
        self.qualityDescription = qualityDescription
        self.status = status
    }
}
