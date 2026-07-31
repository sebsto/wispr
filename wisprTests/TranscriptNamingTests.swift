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

@Suite("TranscriptStore rename Tests", .serialized)
struct TranscriptRenameTests {

    /// Runs `body` and removes every transcript file it added.
    ///
    /// A before/after directory diff rather than a tracked URL list: this suite
    /// renames files, so a tracked URL is stale as soon as a rename runs, and a
    /// failure part-way through would leave the renamed file behind in the user's
    /// real transcripts folder.
    private func withCleanup(_ body: (inout [URL]) throws -> Void) throws {
        let before = Self.directorySnapshot()
        var created: [URL] = []
        defer { Self.removeFilesAdded(since: before) }
        try body(&created)
    }

    private static func directorySnapshot() -> Set<String> {
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: TranscriptStore.directory.path)
        return Set(contents ?? [])
    }

    private static func removeFilesAdded(since snapshot: Set<String>) {
        for name in directorySnapshot().subtracting(snapshot) {
            try? FileManager.default.removeItem(
                at: TranscriptStore.directory.appendingPathComponent(name))
        }
    }

    private func makeTranscript(start: Date = Date()) -> MeetingTranscript {
        var transcript = MeetingTranscript(startTime: start)
        transcript.entries.append(
            MeetingTranscriptEntry(speaker: .you, text: "bonjour", timestamp: start))
        return transcript
    }

    @Test("Renaming puts the title in the filename")
    func testRenamePutsTitleInFilename() throws {
        try withCleanup { created in
            let start = Date()
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
    func testRenamedFileStaysListed() throws {
        try withCleanup { created in
            // list() filters on the `meeting-` prefix, so a free-form name would
            // make the transcript vanish from the history sidebar.
            let start = Date()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let renamed = try TranscriptStore.rename(
                at: original, startTime: start, title: "Sprint review")
            created.append(renamed)

            #expect(TranscriptStore.list().contains { $0.url == renamed })
        }
    }

    @Test("Content survives the rename")
    func testContentPreserved() throws {
        try withCleanup { created in
            let start = Date()
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
    func testClearingTitleRestoresDateName() throws {
        try withCleanup { created in
            let start = Date()
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
    func testSameTitleDoesNotBumpSuffix() throws {
        try withCleanup { created in
            // The file being renamed must be excluded from the collision check, or
            // renaming to the name it already has would produce a `-2` copy.
            let start = Date()
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
    func testCollidingTitlesGetSuffix() throws {
        try withCleanup { created in
            let start = Date()
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
    func testUnusableTitleFallsBackToTimestamp() throws {
        try withCleanup { created in
            let start = Date()
            let original = try #require(TranscriptStore.save(makeTranscript(start: start)))
            created.append(original)

            let renamed = try TranscriptStore.rename(at: original, startTime: start, title: "🎉")
            created.append(renamed)

            #expect(renamed.lastPathComponent == original.lastPathComponent)
        }
    }
}

@Suite("Finder rename adoption Tests", .serialized)
struct TranscriptFilenameAdoptionTests {

    private func withCleanup(_ body: (inout [URL]) throws -> Void) throws {
        let before = Self.directorySnapshot()
        var created: [URL] = []
        defer { Self.removeFilesAdded(since: before) }
        try body(&created)
    }

    private static func directorySnapshot() -> Set<String> {
        let contents = try? FileManager.default.contentsOfDirectory(
            atPath: TranscriptStore.directory.path)
        return Set(contents ?? [])
    }

    private static func removeFilesAdded(since snapshot: Set<String>) {
        for name in directorySnapshot().subtracting(snapshot) {
            try? FileManager.default.removeItem(
                at: TranscriptStore.directory.appendingPathComponent(name))
        }
    }

    private func makeTranscript(start: Date = Date()) -> MeetingTranscript {
        var transcript = MeetingTranscript(startTime: start)
        transcript.entries.append(
            MeetingTranscriptEntry(speaker: .you, text: "bonjour", timestamp: start))
        return transcript
    }

    // MARK: - Fragment extraction

    @Test("The title fragment is read from past the timestamp, which is full of dashes")
    func testFragmentExtraction() {
        let dir = TranscriptStore.directory
        #expect(
            TranscriptStore.titleFragment(
                in: dir.appendingPathComponent("meeting-2026-07-31_11-12-57-ALLO.json")) == "ALLO")
        #expect(
            TranscriptStore.titleFragment(
                in: dir.appendingPathComponent("meeting-2026-07-31_11-12-57.json")) == "")
        #expect(
            TranscriptStore.titleFragment(
                in: dir.appendingPathComponent("meeting-2026-07-31_11-12-57-Sprint-review.json"))
                == "Sprint-review")
    }

    @Test("A name typed in Finder becomes the session name")
    func testTitleFromFilename() {
        let dir = TranscriptStore.directory
        #expect(
            TranscriptStore.titleFromFilename(
                dir.appendingPathComponent("meeting-2026-07-31_11-12-57-ALLO.json")) == "ALLO")
        #expect(
            TranscriptStore.titleFromFilename(
                dir.appendingPathComponent("meeting-2026-07-31_11-12-57-Sprint-review.json"))
                == "Sprint review")
        #expect(
            TranscriptStore.titleFromFilename(
                dir.appendingPathComponent("meeting-2026-07-31_11-12-57.json")) == nil)
    }

    @Test("A collision suffix is not mistaken for a name")
    func testCollisionSuffixIsNotAName() {
        // `fileURL` appends `-2` when two meetings start in the same second. Reading
        // that back as a title would name an untitled session "2".
        let dir = TranscriptStore.directory
        #expect(
            TranscriptStore.titleFromFilename(
                dir.appendingPathComponent("meeting-2026-07-31_11-12-57-2.json")) == nil)

        let reconciled = TranscriptStore.reconciledTitle(
            for: dir.appendingPathComponent("meeting-2026-07-31_11-12-57-2.json"),
            storedTitle: nil)
        #expect(reconciled.title == nil)
        #expect(reconciled.changed == false)
    }

    // MARK: - Reconciliation

    @Test("A title whose punctuation the filename cannot carry is left alone")
    func testLossyTitleIsPreserved() {
        // "Q3: roadmap" slugs to "Q3-roadmap". Naively reading the filename back
        // would rewrite the title as "Q3 roadmap" on every single scan.
        let url = TranscriptStore.directory
            .appendingPathComponent("meeting-2026-07-31_11-12-57-Q3-roadmap.json")

        let reconciled = TranscriptStore.reconciledTitle(for: url, storedTitle: "Q3: roadmap")

        #expect(reconciled.title == "Q3: roadmap")
        #expect(reconciled.changed == false)
    }

    @Test("A filename that genuinely disagrees wins")
    func testExternalRenameWins() {
        let url = TranscriptStore.directory
            .appendingPathComponent("meeting-2026-07-31_11-12-57-ALLO.json")

        let reconciled = TranscriptStore.reconciledTitle(for: url, storedTitle: "Sprint review")

        #expect(reconciled.title == "ALLO")
        #expect(reconciled.changed)
    }

    @Test("Renaming back to the bare timestamp clears the name")
    func testStrippingFragmentClearsTitle() {
        // Symmetric with clearing the title in the app, which removes the fragment.
        let url = TranscriptStore.directory
            .appendingPathComponent("meeting-2026-07-31_11-12-57.json")

        let reconciled = TranscriptStore.reconciledTitle(for: url, storedTitle: "Sprint review")

        #expect(reconciled.title == nil)
        #expect(reconciled.changed)
    }

    @Test("Reconciliation is idempotent — a scan does not keep rewriting files")
    func testIdempotent() throws {
        try withCleanup { created in
            let start = Date()
            var transcript = makeTranscript(start: start)
            transcript.setTitle("Sprint review")
            let url = try #require(TranscriptStore.save(transcript))
            created.append(url)

            TranscriptStore.reconcileTitleWithFilename(at: url)
            let firstPass = try TranscriptStore.load(url).title
            let stamp = try #require(
                FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

            TranscriptStore.reconcileTitleWithFilename(at: url)
            let secondPass = try TranscriptStore.load(url).title
            let stampAfter = try #require(
                FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date)

            #expect(firstPass == "Sprint review")
            #expect(secondPass == "Sprint review")
            // No rewrite on the second pass.
            #expect(stamp == stampAfter)
        }
    }

    // MARK: - End to end

    @Test("Renaming the file in Finder renames the session in the app")
    func testFinderRenamePropagatesToApp() throws {
        try withCleanup { created in
            let start = Date()
            var transcript = makeTranscript(start: start)
            transcript.setTitle("Sprint review")
            let original = try #require(TranscriptStore.save(transcript))
            created.append(original)

            // What Finder does: move the file, leaving the JSON untouched.
            let renamed = original.deletingLastPathComponent()
                .appendingPathComponent(
                    "meeting-\(Self.stamp(start))-ALLO.json")
            try FileManager.default.moveItem(at: original, to: renamed)
            created.append(renamed)

            let listed = try #require(TranscriptStore.list().first { $0.url == renamed })

            #expect(listed.title == "ALLO")
            // Persisted, so an export does not disagree with the sidebar.
            #expect(try TranscriptStore.load(renamed).title == "ALLO")
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }
}
