//
//  TextCorrectionService.swift
//  wispr
//
//  On-device AI text correction using Apple's FoundationModels framework.
//  Wraps SystemLanguageModel to correct grammar and improve spoken-to-written fluency.
//

import Foundation
import FoundationModels
import Observation
import os

/// Protocol for text correction, enabling dependency injection in tests.
@MainActor
protocol TextCorrecting: Sendable {
    var availability: TextCorrectionAvailability { get }
    func checkAvailability()
    func correctText(_ text: String, style: CorrectionStyle) async -> String
}

enum TextCorrectionAvailability: Sendable, Equatable {
    case available
    case notAvailable(reason: String)
    case checking
}

@MainActor
@Observable
final class TextCorrectionService: TextCorrecting {
    private(set) var availability: TextCorrectionAvailability = .checking

    func checkAvailability() {
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            availability = .available
        case .unavailable(.deviceNotEligible):
            availability = .notAvailable(reason: "This Mac does not support Apple Intelligence")
        case .unavailable(.appleIntelligenceNotEnabled):
            availability = .notAvailable(reason: "Apple Intelligence is not enabled in System Settings")
        case .unavailable(.modelNotReady):
            availability = .notAvailable(reason: "Apple Intelligence model is not ready yet")
        case .unavailable(_):
            availability = .notAvailable(reason: "Apple Intelligence is not available")
        @unknown default:
            availability = .notAvailable(reason: "Apple Intelligence is not available")
        }
    }

    func correctText(_ text: String, style: CorrectionStyle) async -> String {
        checkAvailability()
        guard case .available = availability else { return text }
        guard !text.isEmpty else { return text }

        // Compute instructions on MainActor before entering the sendable closure
        let instructions = systemInstructions(for: style)

        do {
            return try await withThrowingTimeout(seconds: 5) {
                let session = LanguageModelSession(
                    model: .default,
                    instructions: instructions
                )
                let response = try await session.respond(to: text)
                let corrected = response.content
                return corrected.isEmpty ? text : corrected
            }
        } catch {
            Log.textCorrection.warning("AI text correction failed: \(error.localizedDescription)")
            return text
        }
    }

    private func systemInstructions(for style: CorrectionStyle) -> String {
        switch style {
        case .minimal:
            """
            You are a silent text correction tool. You receive spoken text and output ONLY \
            the corrected version — nothing else. No introductions, no commentary, no quotes.

            Rules:
            - Fix grammar errors and typos.
            - Remove speech artifacts: false starts, repetitions, filler words (um, uh, you know, like, etc.).
            - Keep the original phrasing, tone, and language. Do NOT translate.
            - Do not change the meaning or add new content.
            - Preserve the original language of the input. If the input is in French, output French. \
            If in Spanish, output Spanish. Never translate to English or any other language.
            - Output the corrected text only. No preamble, no explanation.
            """
        case .fullRephrase:
            """
            You are a silent text rewriting tool. You receive spoken text and output ONLY \
            the rewritten version — nothing else. No introductions, no commentary, no quotes.

            Rules:
            - Rewrite the spoken text as polished, natural written prose.
            - Fix grammar, improve sentence structure and flow.
            - Preserve the original meaning and key details. Do not add information.
            - Preserve the original language of the input. If the input is in French, output French. \
            If in Spanish, output Spanish. Never translate to English or any other language.
            - Output the rewritten text only. No preamble, no explanation.
            """
        }
    }
}

// MARK: - Timeout Helper

/// Races an async operation against a timeout.
/// Returns the operation result if it completes within the deadline,
/// otherwise throws CancellationError.
private func withThrowingTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @Sendable @escaping () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw CancellationError()
        }
        let result = try await group.next()!
        group.cancelAll()
        return result
    }
}
