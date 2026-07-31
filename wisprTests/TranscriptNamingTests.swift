//
//  TranscriptNamingTests.swift
//  wisprTests
//
//  Covers the filename side of transcript storage: how a session title becomes a
//  filename fragment, and how renaming a session moves its file on disk.
//

import Foundation
import Testing

@testable import WisprApp

@Suite("Transcript filename slug Tests")
struct TranscriptSlugTests {

    @Test("A plain title becomes a dashed slug")
    func testSimpleTitle() {
        #expect(TranscriptStore.slug(from: "Sprint review") == "Sprint-review")
    }

    @Test("Characters illegal in a filename are replaced, not dropped silently")
    func testPathSeparatorsAreNeutralised() {
        // `/` is a path separator and `:` is shown as one by Finder; either landing
        // in a filename verbatim would create a file somewhere unintended.
        let slug = TranscriptStore.slug(from: "Q3: roadmap / planning")
        #expect(!slug.contains("/"))
        #expect(!slug.contains(":"))
        #expect(slug == "Q3-roadmap-planning")
    }

    @Test("Runs of punctuation and whitespace collapse into one separator")
    func testSeparatorsCollapse() {
        #expect(TranscriptStore.slug(from: "one   --  two") == "one-two")
    }

    @Test("A slug never starts or ends with a separator")
    func testNoEdgeSeparators() {
        let slug = TranscriptStore.slug(from: "  ...weekly sync!!!  ")
        #expect(slug == "weekly-sync")
        #expect(!slug.hasPrefix("-"))
        #expect(!slug.hasSuffix("-"))
    }

    @Test("Accented letters survive")
    func testAccentsKept() {
        // APFS stores these fine, and stripping them would mangle French titles.
        #expect(TranscriptStore.slug(from: "réunion équipe") == "réunion-équipe")
    }

    @Test("A title with nothing filename-safe in it yields an empty slug")
    func testUnusableTitle() {
        // Callers fall back to the timestamp-only name rather than producing a file
        // called just "-" or "".
        #expect(TranscriptStore.slug(from: "🎉🎉🎉") == "")
        #expect(TranscriptStore.slug(from: "///") == "")
        #expect(TranscriptStore.slug(from: nil) == "")
        #expect(TranscriptStore.slug(from: "") == "")
    }

    @Test("A very long title is truncated without a trailing separator")
    func testTruncation() {
        let slug = TranscriptStore.slug(from: String(repeating: "ab ", count: 100))
        #expect(slug.count <= 60)
        #expect(!slug.hasSuffix("-"))
    }
}

@Suite("TranscriptStore rename Tests", .serialized, .transcriptDirectoryIsolated)
struct TranscriptRenameTests {

    /// Runs `body` and deletes every file it registered, so the suite leaves the
    /// real transcripts directory as it found it.
    ///
    /// Tests that rename a file must register the new URL too: renaming is the
    /// point of this suite, and a URL captured before a rename no longer exists.
    ///
    /// Held under `TestTranscriptDirectoryLock` because other suites share this
    /// directory — one of them redirects it process-wide — and a parallel redirect
    /// would point `TranscriptStore` at a different folder mid-test.
    private func withCleanup(_ body: (inout [URL]) throws -> Void) async throws {
        var created: [URL] = []
        defer { for url in created { try? TranscriptStore.delete(url) } }
        try body(&created)
    }

    private func makeTranscript(start: Date = TestTranscriptClock.nextStart()) -> MeetingTranscript {
        var transcript = MeetingTranscript(startTime: start)
        transcript.entries.append(
            MeetingTranscriptEntry(speaker: .you, text: "bonjour", timestamp: start))
        return transcript
    }

    @Test("Renaming puts the title in the filename")
    func testRenamePutsTitleInFilename() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let renamed = try TranscriptStore.rename(
                at: original, startTime: start, title: "Sprint review")
            created.append(renamed)

            #expect(renamed.lastPathComponent.contains("Sprint-review"))
            #expect(FileManager.default.fileExists(atPath: renamed.path))
            #expect(!FileManager.default.fileExists(atPath: original.path))
        }
    }

    @Test("A renamed file is still found by list()")
    func testRenamedFileStaysListed() async throws {
        try await withCleanup { created in
            // list() filters on the `meeting-` prefix, so a free-form name would
            // make the transcript vanish from the history sidebar.
            let start = TestTranscriptClock.nextStart()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let renamed = try TranscriptStore.rename(
                at: original, startTime: start, title: "Sprint review")
            created.append(renamed)

            #expect(TranscriptStore.list().contains { $0.url == renamed })
        }
    }

    @Test("Content survives the rename")
    func testContentPreserved() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            var transcript = makeTranscript(start: start)
            transcript.setTitle("Sprint review")
            let original = try #require(TranscriptStore.save(transcript))
            created.append(original)

            let renamed = try TranscriptStore.rename(
                at: original, startTime: start, title: "Sprint review")
            created.append(renamed)

            let loaded = try TranscriptStore.load(renamed)
            #expect(loaded.title == "Sprint review")
            #expect(loaded.entries.map(\.text) == ["bonjour"])
        }
    }

    @Test("Clearing the title returns the file to its timestamp-only name")
    func testClearingTitleRestoresDateName() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let named = try TranscriptStore.rename(
                at: original, startTime: start, title: "Sprint review")
            created.append(named)

            let cleared = try TranscriptStore.rename(at: named, startTime: start, title: nil)
            created.append(cleared)

            #expect(cleared.lastPathComponent == original.lastPathComponent)
            #expect(!cleared.lastPathComponent.contains("Sprint-review"))
        }
    }

    @Test("Re-applying the same title is a no-op rather than adding a suffix")
    func testSameTitleDoesNotBumpSuffix() async throws {
        try await withCleanup { created in
            // The file being renamed must be excluded from the collision check, or
            // renaming to the name it already has would produce a `-2` copy.
            let start = TestTranscriptClock.nextStart()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let first = try TranscriptStore.rename(
                at: original, startTime: start, title: "Sprint review")
            created.append(first)

            let second = try TranscriptStore.rename(
                at: first, startTime: start, title: "Sprint review")

            #expect(second == first)
            #expect(!second.lastPathComponent.contains("-2."))
        }
    }

    @Test("Two sessions in the same second given the same title stay distinct files")
    func testCollidingTitlesGetSuffix() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let first = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(first)
            let second = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(second)

            let firstNamed = try TranscriptStore.rename(
                at: first, startTime: start, title: "Standup")
            created.append(firstNamed)
            let secondNamed = try TranscriptStore.rename(
                at: second, startTime: start, title: "Standup")
            created.append(secondNamed)

            #expect(firstNamed != secondNamed)
            #expect(FileManager.default.fileExists(atPath: firstNamed.path))
            #expect(FileManager.default.fileExists(atPath: secondNamed.path))
        }
    }

    @Test("A title with nothing usable in it falls back to the timestamp name")
    func testUnusableTitleFallsBackToTimestamp() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let renamed = try TranscriptStore.rename(at: original, startTime: start, title: "🎉")
            created.append(renamed)

            #expect(renamed.lastPathComponent == original.lastPathComponent)
        }
    }
}
