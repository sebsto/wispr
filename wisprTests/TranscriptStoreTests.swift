//
//  TranscriptStoreTests.swift
//  wisprTests
//
//  Covers transcript persistence: JSON backward compatibility, the
//  list/load/delete API, filename collisions, and corrupt-file resilience.
//

import Foundation
import Testing

@testable import WisprApp

// MARK: - JSON Compatibility

@Suite("MeetingTranscript Codable Tests")
struct MeetingTranscriptCodableTests {

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    @Test("Legacy JSON without speakerNames decodes with an empty map")
    func testLegacyDecode() throws {
        // Shape written by every wispr version before speaker naming existed.
        // The compiler-synthesized init(from:) would reject this with
        // keyNotFound, making all previously-saved transcripts unreadable.
        let legacy = """
            {
              "entries": [
                {
                  "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
                  "speaker": { "you": {} },
                  "text": "bonjour",
                  "timestamp": "2026-07-20T09:05:23Z"
                }
              ],
              "startTime": "2026-07-20T09:05:00Z"
            }
            """

        let transcript = try decoder.decode(
            MeetingTranscript.self, from: Data(legacy.utf8))

        #expect(transcript.speakerNames.isEmpty)
        #expect(transcript.entries.count == 1)
        #expect(transcript.entries[0].text == "bonjour")
    }

    @Test("speakerNames survives an encode/decode round-trip")
    func testSpeakerNamesRoundTrip() throws {
        var transcript = MeetingTranscript(startTime: Date(timeIntervalSince1970: 1_000))
        transcript.entries.append(
            MeetingTranscriptEntry(
                speaker: .others(speakerIndex: 0), text: "salut",
                timestamp: Date(timeIntervalSince1970: 1_010))
        )
        transcript.setName("Alice", forSpeakerIndex: 0)

        let restored = try decoder.decode(
            MeetingTranscript.self, from: encoder.encode(transcript))

        #expect(restored.speakerNames == ["0": "Alice"])
        #expect(restored.displayName(for: .others(speakerIndex: 0)) == "Alice")
    }

    @Test("Legacy JSON without title decodes with no title")
    func testLegacyDecodeWithoutTitle() throws {
        // Same guard as speakerNames: the synthesized init(from:) would reject a
        // file that predates the field, making every saved transcript unreadable.
        let legacy = """
            {
              "entries": [],
              "startTime": "2026-07-20T09:05:00Z"
            }
            """

        let transcript = try decoder.decode(MeetingTranscript.self, from: Data(legacy.utf8))

        #expect(transcript.title == nil)
    }

    @Test("A session title survives an encode/decode round-trip")
    func testTitleRoundTrip() throws {
        var transcript = MeetingTranscript(startTime: Date(timeIntervalSince1970: 1_000))
        transcript.setTitle("Sprint review")

        let restored = try decoder.decode(
            MeetingTranscript.self, from: encoder.encode(transcript))

        #expect(restored.title == "Sprint review")
    }

    @Test("Blank titles clear back to nil rather than storing whitespace")
    func testTitleTrimmingAndClearing() {
        var transcript = MeetingTranscript()

        transcript.setTitle("  Sprint review \n")
        #expect(transcript.title == "Sprint review")

        transcript.setTitle("   ")
        #expect(transcript.title == nil)

        transcript.setTitle("Sprint review")
        transcript.setTitle(nil)
        #expect(transcript.title == nil)
    }

    @Test("Malformed JSON throws rather than producing a partial transcript")
    func testMalformedDecodeThrows() {
        let broken = Data("{ \"entries\": [ ".utf8)
        #expect(throws: (any Error).self) {
            try decoder.decode(MeetingTranscript.self, from: broken)
        }
    }
}

// MARK: - Speaker Names

@Suite("MeetingTranscript Speaker Name Tests")
struct MeetingTranscriptSpeakerNameTests {

    @Test("Unnamed speakers fall back to the generic label")
    func testFallbackLabels() {
        let transcript = MeetingTranscript()

        #expect(transcript.displayName(for: .you) == "You")
        #expect(transcript.displayName(for: .others(speakerIndex: nil)) == "Others")
        // 0-based internally, 1-based in the label.
        #expect(transcript.displayName(for: .others(speakerIndex: 0)) == "Speaker 1")
        #expect(transcript.displayName(for: .others(speakerIndex: 2)) == "Speaker 3")
    }

    @Test("Naming a speaker relabels all of their entries at once")
    func testRenameAppliesRetroactively() {
        var transcript = MeetingTranscript()
        for text in ["un", "deux"] {
            transcript.entries.append(
                MeetingTranscriptEntry(speaker: .others(speakerIndex: 1), text: text))
        }

        transcript.setName("Bob", forSpeakerIndex: 1)

        // Names resolve at display time, so no entry had to be rewritten.
        for entry in transcript.entries {
            #expect(transcript.displayName(for: entry.speaker) == "Bob")
        }
    }

    @Test("Blank or nil names clear the assignment")
    func testClearingAName() {
        var transcript = MeetingTranscript()
        transcript.setName("Alice", forSpeakerIndex: 0)

        transcript.setName("   ", forSpeakerIndex: 0)
        #expect(transcript.displayName(for: .others(speakerIndex: 0)) == "Speaker 1")

        transcript.setName("Alice", forSpeakerIndex: 0)
        transcript.setName(nil, forSpeakerIndex: 0)
        #expect(transcript.speakerNames.isEmpty)
    }

    @Test("Names are trimmed before being stored")
    func testNameIsTrimmed() {
        var transcript = MeetingTranscript()
        transcript.setName("  Charlie \n", forSpeakerIndex: 0)
        #expect(transcript.speakerNames["0"] == "Charlie")
    }

    @Test("presentSpeakerIndices lists speakers once, in order of first appearance")
    func testPresentSpeakerIndices() {
        var transcript = MeetingTranscript()
        let speakers: [MeetingSpeaker] = [
            .others(speakerIndex: 2),
            .you,
            .others(speakerIndex: 0),
            .others(speakerIndex: 2),
            .others(speakerIndex: nil),
        ]
        for (i, speaker) in speakers.enumerated() {
            transcript.entries.append(
                MeetingTranscriptEntry(speaker: speaker, text: "line \(i)"))
        }

        // "You" and unresolved "Others" are not renameable speakers.
        #expect(transcript.presentSpeakerIndices == [2, 0])
    }

    @Test("Plain-text export uses assigned names")
    func testExportUsesNames() {
        var transcript = MeetingTranscript()
        transcript.entries.append(
            MeetingTranscriptEntry(speaker: .others(speakerIndex: 0), text: "hello"))
        transcript.setName("Alice", forSpeakerIndex: 0)

        let text = transcript.asPlainText()
        #expect(text.contains("Alice: hello"))
        #expect(!text.contains("Speaker 1"))
    }
}

// MARK: - Duration

@Suite("MeetingTranscript Duration Tests")
struct MeetingTranscriptDurationTests {

    @Test("contentDuration spans the entries, not the wall clock")
    func testContentDuration() {
        let start = Date(timeIntervalSince1970: 1_000)
        var transcript = MeetingTranscript(startTime: start)
        transcript.entries.append(
            MeetingTranscriptEntry(
                speaker: .you, text: "a", timestamp: start.addingTimeInterval(65)))

        // `duration` is now-relative and would report decades for this date;
        // `contentDuration` is what the history list must use.
        #expect(transcript.contentDuration == 65)
        #expect(transcript.formattedContentDuration == "1:05")
    }

    @Test("An empty transcript has zero content duration")
    func testEmptyContentDuration() {
        #expect(MeetingTranscript().contentDuration == 0)
    }

    @Test("Durations past an hour include the hour component")
    func testHourFormatting() {
        #expect(MeetingTranscript.formatDuration(59) == "0:59")
        #expect(MeetingTranscript.formatDuration(60) == "1:00")
        #expect(MeetingTranscript.formatDuration(3_599) == "59:59")
        #expect(MeetingTranscript.formatDuration(3_600) == "1:00:00")
        #expect(MeetingTranscript.formatDuration(3_725) == "1:02:05")
    }

    @Test("Negative durations clamp to zero rather than formatting oddly")
    func testNegativeDuration() {
        #expect(MeetingTranscript.formatDuration(-10) == "0:00")
    }
}

// MARK: - Store

@Suite("TranscriptStore Tests", .serialized, .transcriptDirectoryIsolated)
struct TranscriptStoreTests {

    /// Files this suite created, so it can leave the real transcripts directory
    /// exactly as it found it.
    ///
    /// Held under `TestTranscriptDirectoryLock`: other suites share this directory
    /// and one of them redirects it process-wide, which would otherwise land
    /// mid-test and point `TranscriptStore` at a different folder.
    private func withCleanup(_ body: (inout [URL]) throws -> Void) async throws {
        var created: [URL] = []
        defer { for url in created { try? TranscriptStore.delete(url) } }
        try body(&created)
    }

    private func makeTranscript(
        start: Date = TestTranscriptClock.nextStart(), texts: [String] = ["hello"]
    ) -> MeetingTranscript {
        var transcript = MeetingTranscript(startTime: start)
        for (i, text) in texts.enumerated() {
            transcript.entries.append(
                MeetingTranscriptEntry(
                    speaker: .you, text: text,
                    timestamp: start.addingTimeInterval(Double(i + 1)))
            )
        }
        return transcript
    }

    @Test("Empty transcripts are not written to disk")
    func testEmptyIsNotSaved() {
        #expect(TranscriptStore.save(MeetingTranscript()) == nil)
    }

    @Test("A saved transcript loads back identically")
    func testSaveThenLoad() async throws {
        try await withCleanup { created in
            var original = makeTranscript(texts: ["un", "deux"])
            original.setName("Alice", forSpeakerIndex: 0)

            let url = try #require(TranscriptStore.save(original))
            created.append(url)

            let loaded = try TranscriptStore.load(url)
            #expect(loaded.entries.map(\.text) == ["un", "deux"])
            #expect(loaded.speakerNames == ["0": "Alice"])
        }
    }

    @Test("Two meetings starting in the same second do not overwrite each other")
    func testFilenameCollision() async throws {
        try await withCleanup { created in
            // Same startTime means the same timestamp-derived filename; without a
            // uniquing suffix the second save would silently destroy the first.
            let start = TestTranscriptClock.nextStart()
            let first = try #require(TranscriptStore.save(makeTranscript(start: start, texts: ["premier"])))
            created.append(first)
            let second = try #require(TranscriptStore.save(makeTranscript(start: start, texts: ["second"])))
            created.append(second)

            #expect(first != second)
            #expect(try TranscriptStore.load(first).entries[0].text == "premier")
            #expect(try TranscriptStore.load(second).entries[0].text == "second")
        }
    }

    @Test("save(to:) overwrites in place instead of creating a second file")
    func testSaveToURLOverwrites() async throws {
        try await withCleanup { created in
            let url = try #require(TranscriptStore.save(makeTranscript()))
            created.append(url)

            var edited = try TranscriptStore.load(url)
            edited.setName("Alice", forSpeakerIndex: 0)
            try TranscriptStore.save(edited, to: url)

            let reloaded = try TranscriptStore.load(url)
            #expect(reloaded.speakerNames == ["0": "Alice"])
            // Still exactly one file for this session.
            #expect(TranscriptStore.list().filter { $0.url == url }.count == 1)
        }
    }

    @Test("list() summarises a saved transcript and sorts newest first")
    func testListSummariesAndOrdering() async throws {
        try await withCleanup { created in
            let older = Date().addingTimeInterval(-3_600)
            let newer = Date()

            var withSpeaker = MeetingTranscript(startTime: newer)
            withSpeaker.entries.append(
                MeetingTranscriptEntry(
                    speaker: .others(speakerIndex: 0), text: "recent line",
                    timestamp: newer.addingTimeInterval(30))
            )
            withSpeaker.setName("Alice", forSpeakerIndex: 0)

            created.append(try #require(TranscriptStore.save(makeTranscript(start: older, texts: ["ancien"]))))
            created.append(try #require(TranscriptStore.save(withSpeaker)))

            let listed = TranscriptStore.list().filter { created.contains($0.url) }
            #expect(listed.count == 2)

            // Newest first.
            #expect(listed[0].startTime > listed[1].startTime)

            let recent = listed[0]
            #expect(recent.entryCount == 1)
            #expect(recent.preview == "recent line")
            #expect(recent.speakerNames == ["Alice"])
            #expect(recent.duration == 30)
            #expect(recent.isUnreadable == false)
        }
    }

    @Test("list() reports a session's title, and its absence")
    func testListReportsTitle() async throws {
        try await withCleanup { created in
            let untitled = try #require(TranscriptStore.save(makeTranscript(texts: ["sans titre"])))
            created.append(untitled)

            var named = makeTranscript(start: Date().addingTimeInterval(-60), texts: ["nommé"])
            named.setTitle("Sprint review")
            let titled = try #require(TranscriptStore.save(named))
            created.append(titled)

            let listed = TranscriptStore.list()
            let untitledRow = try #require(listed.first { $0.url == untitled })
            let titledRow = try #require(listed.first { $0.url == titled })

            #expect(untitledRow.title == nil)
            #expect(untitledRow.hasTitle == false)
            #expect(titledRow.title == "Sprint review")
            #expect(titledRow.hasTitle)
        }
    }

    @Test("A corrupt file appears as an unreadable row instead of breaking the scan")
    func testCorruptFileIsListedNotSkipped() async throws {
        try await withCleanup { created in
            let good = try #require(TranscriptStore.save(makeTranscript(texts: ["valide"])))
            created.append(good)

            // Must match the store's naming convention to be picked up at all.
            let corrupt = TranscriptStore.directory
                .appendingPathComponent("meeting-9999-01-01_00-00-00.json")
            try Data("not json at all".utf8).write(to: corrupt)
            created.append(corrupt)

            let listed = TranscriptStore.list()
            let corruptRow = try #require(listed.first { $0.url == corrupt })

            #expect(corruptRow.isUnreadable)
            #expect(corruptRow.entryCount == 0)
            // The healthy file is still listed — the scan did not abort.
            #expect(listed.contains { $0.url == good && !$0.isUnreadable })
        }
    }

    @Test("Non-transcript files in the directory are ignored")
    func testUnrelatedFilesIgnored() async throws {
        try await withCleanup { created in
            let stray = TranscriptStore.directory.appendingPathComponent("notes.txt")
            try FileManager.default.createDirectory(
                at: TranscriptStore.directory, withIntermediateDirectories: true)
            try Data("scratch".utf8).write(to: stray)
            defer { try? FileManager.default.removeItem(at: stray) }

            #expect(!TranscriptStore.list().contains { $0.url == stray })
        }
    }

    @Test("delete() removes the file from disk and from the listing")
    func testDelete() throws {
        let url = try #require(TranscriptStore.save(makeTranscript()))
        #expect(TranscriptStore.list().contains { $0.url == url })

        try TranscriptStore.delete(url)

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!TranscriptStore.list().contains { $0.url == url })
    }

    @Test("Deleting a file that is already gone throws rather than failing silently")
    func testDeleteMissingFileThrows() {
        let missing = TranscriptStore.directory
            .appendingPathComponent("meeting-1970-01-01_00-00-00.json")
        #expect(throws: (any Error).self) {
            try TranscriptStore.delete(missing)
        }
    }
}
