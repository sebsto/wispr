//
//  TextInsertionServiceTests.swift
//  wispr
//
//  Unit tests for TextInsertionService using swift-testing framework
//
//  **Validates: Requirements 4.2, 4.5**
//

import Testing
import Foundation
import AppKit
@testable import wispr

// MARK: - Mock

@MainActor
final class MockTextInsertionService: TextInserting {
    var insertedTexts: [String] = []
    var shouldThrow: WispError?

    func insertText(_ text: String) async throws {
        if let error = shouldThrow {
            throw error
        }
        insertedTexts.append(text)
    }
}

// MARK: - Tests

@Suite("TextInsertionService Tests")
struct TextInsertionServiceTests {

    @Test("insertText records the inserted text")
    @MainActor
    func testInsertTextRecordsText() async throws {
        let mock = MockTextInsertionService()

        try await mock.insertText("Hello world")

        #expect(mock.insertedTexts == ["Hello world"])
    }

    @Test("insertText propagates errors")
    @MainActor
    func testInsertTextThrows() async {
        let mock = MockTextInsertionService()
        mock.shouldThrow = .textInsertionFailed("Simulated failure")

        await #expect(throws: WispError.self) {
            try await mock.insertText("Should fail")
        }
        #expect(mock.insertedTexts.isEmpty)
    }

    @Test("insertText handles empty text")
    @MainActor
    func testInsertEmptyText() async throws {
        let mock = MockTextInsertionService()

        try await mock.insertText("")

        #expect(mock.insertedTexts == [""])
    }

    @Test("insertText handles unicode text")
    @MainActor
    func testInsertUnicodeText() async throws {
        let mock = MockTextInsertionService()
        let unicode = "こんにちは世界 🌍 مرحبا"

        try await mock.insertText(unicode)

        #expect(mock.insertedTexts == [unicode])
    }

    @Test("insertText handles long text")
    @MainActor
    func testInsertLongText() async throws {
        let mock = MockTextInsertionService()
        let longText = String(repeating: "Hello world. ", count: 1000)

        try await mock.insertText(longText)

        #expect(mock.insertedTexts.first == longText)
    }

    @Test("multiple insertions are recorded in order")
    @MainActor
    func testMultipleInsertions() async throws {
        let mock = MockTextInsertionService()

        try await mock.insertText("first")
        try await mock.insertText("second")
        try await mock.insertText("third")

        #expect(mock.insertedTexts == ["first", "second", "third"])
    }
}
