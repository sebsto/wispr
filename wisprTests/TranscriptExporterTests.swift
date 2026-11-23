//
//  TranscriptExporterTests.swift
//  wisprTests
//
//  Covers export file naming, subfolder rules, collision handling, and folder access.
//

import Foundation
import Testing

@testable import WisprApp

@Suite("Transcript exporter Tests")
struct TranscriptExporterTests {

    /// A fresh empty directory, removed by the caller's `defer`.
    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makeTranscript(title: String? = "Sprint review") -> MeetingTranscript {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var transcript = MeetingTranscript(startTime: start)
        transcript.title = title
        transcript.entries = [
            MeetingTranscriptEntry(speaker: .you, text: "Hello.", timestamp: start.addingTimeInterval(3))
        ]
        return transcript
    }

    // MARK: - Naming

    @Test("The stem is the start time, then the title slug when there is one")
    func testStem() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let bare = TranscriptExporter.fileStem(startTime: start, title: nil)
        let titled = TranscriptExporter.fileStem(startTime: start, title: "Sprint review")

        #expect(bare.range(of: #"^\d{4}-\d{2}-\d{2}-\d{2}-\d{2}$"#, options: .regularExpression) != nil)
        #expect(titled == "\(bare)-Sprint-review")
    }

    @Test("A title with nothing usable falls back to the bare timestamp")
    func testStemWithPunctuationOnlyTitle() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(
            TranscriptExporter.fileStem(startTime: start, title: "???")
                == TranscriptExporter.fileStem(startTime: start, title: nil))
    }

    // MARK: - Subfolder validation

    @Test("Plain names and an empty subfolder are valid", arguments: ["", "Transcripts", "Meeting notes", "  "])
    func testValidSubfolders(name: String) {
        #expect(TranscriptExporter.isValid(subfolder: name))
    }

    @Test(
        "Names that could leave the chosen folder are rejected",
        arguments: ["..", ".", "../x", "a/b", "a\\b", "/abs", ".obsidian", "a:b"])
    func testInvalidSubfolders(name: String) {
        #expect(!TranscriptExporter.isValid(subfolder: name))
    }

    // MARK: - Writing

    @Test("A file is written into the folder")
    func testWrite() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try TranscriptExporter.write(
            markdown: "hello", stem: "note", in: folder, subfolder: "")
        #expect(url.lastPathComponent == "note.md")
        #expect(try String(contentsOf: url, encoding: .utf8) == "hello")
    }

    @Test("The subfolder is created when missing")
    func testSubfolderCreated() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let url = try TranscriptExporter.write(
            markdown: "x", stem: "note", in: folder, subfolder: "Transcripts")
        #expect(url.deletingLastPathComponent().lastPathComponent == "Transcripts")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test("An invalid subfolder writes nothing")
    func testInvalidSubfolderWritesNothing() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        #expect(throws: TranscriptExporter.ExportError.invalidSubfolder) {
            try TranscriptExporter.write(markdown: "x", stem: "note", in: folder, subfolder: "..")
        }
        let contents = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(contents.isEmpty)
    }

    @Test("A taken name gets a numeric suffix and the original is kept")
    func testCollisionSuffix() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let first = try TranscriptExporter.write(markdown: "one", stem: "note", in: folder, subfolder: "")
        let second = try TranscriptExporter.write(markdown: "two", stem: "note", in: folder, subfolder: "")
        let third = try TranscriptExporter.write(markdown: "three", stem: "note", in: folder, subfolder: "")

        #expect(first.lastPathComponent == "note.md")
        #expect(second.lastPathComponent == "note-2.md")
        #expect(third.lastPathComponent == "note-3.md")
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")
    }

    // MARK: - Folder access

    /// Whether this machine can create security-scoped bookmarks. A headless or
    /// remote session has no `ScopedBookmarksAgent`, so the bookmark tests are
    /// skipped there instead of failing for a reason unrelated to the exporter.
    nonisolated private static let canMakeScopedBookmarks: Bool = {
        let folder = FileManager.default.temporaryDirectory
        return (try? TranscriptExporter.makeBookmark(for: folder)) != nil
    }()

    @Test(
        "A bookmark round-trips to the folder and the export lands in it",
        .enabled(if: TranscriptExporterTests.canMakeScopedBookmarks))
    func testExportThroughBookmark() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = TranscriptExportConfig()
        config.enabled = true
        config.folderBookmark = try TranscriptExporter.makeBookmark(for: folder)
        config.subfolder = "Transcripts"

        let result = try TranscriptExporter.export(makeTranscript(), using: config)
        let written = try String(contentsOf: result.url, encoding: .utf8)

        #expect(result.url.deletingLastPathComponent().lastPathComponent == "Transcripts")
        #expect(result.url.pathExtension == "md")
        #expect(written.hasPrefix("---\ntitle: \"Sprint review\""))
    }

    @Test(
        "Frontmatter can be left out of the exported file",
        .enabled(if: TranscriptExporterTests.canMakeScopedBookmarks))
    func testExportWithoutFrontmatter() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var config = TranscriptExportConfig()
        config.folderBookmark = try TranscriptExporter.makeBookmark(for: folder)
        config.includeFrontmatter = false

        let result = try TranscriptExporter.export(makeTranscript(), using: config)
        #expect(try String(contentsOf: result.url, encoding: .utf8).hasPrefix("# Sprint review"))
    }

    @Test("An unusable bookmark reports the folder as unavailable")
    func testBadBookmark() {
        var config = TranscriptExportConfig()
        config.folderBookmark = Data("not a bookmark".utf8)

        #expect(throws: TranscriptExporter.ExportError.self) {
            try TranscriptExporter.export(makeTranscript(), using: config)
        }
    }

    @Test("A missing bookmark reports the folder as unavailable")
    func testNoBookmark() {
        #expect(throws: TranscriptExporter.ExportError.self) {
            try TranscriptExporter.export(makeTranscript(), using: TranscriptExportConfig())
        }
    }
}
