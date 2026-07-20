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
@testable import WisprApp
import WisprCore

// MARK: - Mock

@MainActor
final class MockTextInsertionService: TextInserting {
    var insertedTexts: [String] = []
    var shouldThrow: WisprError?
    var simulateEnterKeyCalled = false

    func insertText(_ text: String) async throws {
        if let error = shouldThrow {
            throw error
        }
        insertedTexts.append(text)
    }

    func simulateEnterKey() {
        simulateEnterKeyCalled = true
    }
}

// MARK: - In-memory pasteboard fake

/// In-memory `TextPasteboard` for deterministic clipboard-restore tests.
@MainActor
final class FakePasteboard: TextPasteboard {
    private var storage: [NSPasteboard.PasteboardType: Data] = [:]
    private(set) var changeCount: Int = 0

    var types: [NSPasteboard.PasteboardType]? { Array(storage.keys) }

    func data(forType type: NSPasteboard.PasteboardType) -> Data? { storage[type] }

    @discardableResult
    func clearContents() -> Int {
        storage.removeAll()
        changeCount += 1
        return changeCount
    }

    @discardableResult
    func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool {
        storage[type] = Data(string.utf8)
        changeCount += 1
        return true
    }

    @discardableResult
    func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool {
        storage[type] = data
        changeCount += 1
        return true
    }

    /// Convenience: current `.string` value, if any.
    var string: String? {
        storage[.string].flatMap { String(data: $0, encoding: .utf8) }
    }
}

// MARK: - Clipboard restore bug reproduction (real service)

@Suite("TextInsertionService clipboard restore")
@MainActor
struct TextInsertionClipboardTests {

    /// Bug 1: a manual copy made during the restore window must NOT be clobbered
    /// by the restore. If the user copies something new after Wispr pastes, the
    /// restore should not overwrite it with the pre-transcription snapshot.
    @Test("restore does not clobber a manual copy made during the window")
    func testManualCopyDuringWindowIsPreserved() async throws {
        let pb = FakePasteboard()
        pb.setString("original", forType: .string)  // user's clipboard before dictation

        let service = TextInsertionService(
            pasteboard: pb,
            restoreDelay: .zero,
            performPaste: { true }
        )

        // Wispr places transcription on the clipboard and "pastes" it.
        try await service.insertText("transcribed text")

        // Before the restore fires, the user manually copies something new.
        pb.setString("user copied this", forType: .string)

        // Let the scheduled restore run.
        await service.awaitPendingPasteboardRestore()

        #expect(pb.string == "user copied this")
    }

    /// Bug 2: if the original clipboard was empty, the transcribed text must not
    /// linger — the clipboard should be cleared, not left holding our text.
    @Test("empty original clipboard is cleared, transcription does not linger")
    func testEmptyOriginalClipboardDoesNotLinger() async throws {
        let pb = FakePasteboard()  // empty: no original contents

        let service = TextInsertionService(
            pasteboard: pb,
            restoreDelay: .zero,
            performPaste: { true }
        )

        try await service.insertText("transcribed text")
        await service.awaitPendingPasteboardRestore()

        #expect(pb.string != "transcribed text", "transcribed text should not linger on the clipboard")
    }

    /// Sanity: the normal case still restores the user's original clipboard.
    @Test("original clipboard is restored after the window")
    func testOriginalClipboardRestored() async throws {
        let pb = FakePasteboard()
        pb.setString("original", forType: .string)

        let service = TextInsertionService(
            pasteboard: pb,
            restoreDelay: .zero,
            performPaste: { true }
        )

        try await service.insertText("transcribed text")
        await service.awaitPendingPasteboardRestore()

        #expect(pb.string == "original")
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

        await #expect(throws: WisprError.self) {
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
