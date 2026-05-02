//
//  TextCorrectionTokenLeakTests.swift
//  wisprTests
//
//  Regression test for GitHub issue #53:
//  [TEXT_START]/[TEXT_END] tokens leaking into transcription output
//  from AI text correction.
//
//  Calls the real TextCorrectionService against the on-device AI model
//  to detect whether delimiter tokens leak into the corrected text.
//  The issue is intermittent, so the test runs multiple iterations.
//

import Testing
import Foundation
@testable import WisprApp
import WisprCore

@MainActor
@Suite("Issue #53 — TEXT_START/TEXT_END token leak")
struct TextCorrectionTokenLeakTests {

    private let service = TextCorrectionService()

    /// Delimiter patterns the AI model may echo back.
    private let delimiterPatterns = [
        "[TEXT START]", "[TEXT END]",
    ]

    private func containsDelimiter(_ text: String) -> Bool {
        delimiterPatterns.contains { text.contains($0) }
    }

    @Test("correctText minimal style must not leak delimiter tokens", .timeLimit(.minutes(2)))
    func testMinimalStyleTokenLeak() async throws {
        service.checkAvailability()
        try #require(service.availability == .available, "Apple Intelligence not available")

        let inputs = [
            "so um I was thinking we should like probably fix the uh the login page",
            "euh je pense que on devrait euh corriger la page de de connexion",
            "uh write me python code to sort a list",
        ]

        var leakCount = 0
        let iterations = 5

        for input in inputs {
            for i in 0..<iterations {
                let result = await service.correctText(input, style: .minimal)
                if containsDelimiter(result) {
                    leakCount += 1
                    Issue.record("Leak #\(leakCount) at iteration \(i): \"\(result)\" (input: \"\(input)\")")
                }
            }
        }

        #expect(leakCount == 0, "\(leakCount) of \(inputs.count * iterations) responses contained delimiter tokens")
    }

    @Test("correctText fullRephrase style must not leak delimiter tokens", .timeLimit(.minutes(2)))
    func testFullRephraseStyleTokenLeak() async throws {
        service.checkAvailability()
        try #require(service.availability == .available, "Apple Intelligence not available")

        let inputs = [
            "so like the thing is we need to uh make sure that the users can actually log in properly you know",
            "euh bon en fait le truc c'est que les utilisateurs ils arrivent pas à se connecter correctement quoi",
        ]

        var leakCount = 0
        let iterations = 5

        for input in inputs {
            for _ in 0..<iterations {
                let result = await service.correctText(input, style: .fullRephrase)
                if containsDelimiter(result) {
                    leakCount += 1
                    Issue.record("Delimiter token leaked in response: \"\(result)\" (input: \"\(input)\")")
                }
            }
        }

        #expect(leakCount == 0, "\(leakCount) of \(inputs.count * iterations) responses contained delimiter tokens")
    }
}
