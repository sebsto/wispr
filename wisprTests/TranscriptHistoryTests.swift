//
//  TranscriptHistoryTests.swift
//  wisprTests
//
//  Unit tests for browsing saved transcripts: list, load, delete, rename, and
//  the archive-safe duration used to describe them.
//

import Foundation
import Testing
import WisprCore

@testable import WisprApp

@Suite("Transcript History Tests")
struct TranscriptHistoryTests {

    /// Fixtures are dated in the year 2000 so their filenames can never collide
    /// with a real recording sitting in the same directory, and a leaked file is
    /// obvious rather than looking like the user's own session.
    private func fixture(
        offsetSeconds: TimeInterval = 0,
        entryTexts: [String] = ["First line", "Second line"],
        entrySpacing: TimeInterval = 30
    ) -> MeetingTranscript {
        let start = Date(timeIntervalSince1970: 946_684_800 + offsetSeconds)  // 2000-01-01
        var transcript = MeetingTranscript(startTime: start)
        for (index, text) in entryTexts.enumerated() {
            transcript.entries.append(
                MeetingTranscriptEntry(
                    speaker: index.isMultiple(of: 2) ? .you : .others(speakerIndex: nil),
                    text: text,
                    timestamp: start.addingTimeInterval(entrySpacing * TimeInterval(index + 1))
                )
            )
        }
        return transcript
    }

    // MARK: - Duration

    @Test("recordedSpan measures first-to-last entry, not time since start")
    func testRecordedSpanIsFixedForArchived() {
        let transcript = fixture(entryTexts: ["a", "b", "c"], entrySpacing: 60)
        // Entries land at +60, +120, +180 from startTime.
        #expect(transcript.recordedSpan == 180)
        #expect(transcript.formattedRecordedSpan == "3:00")
    }

    @Test("formattedRecordedSpan renders hours instead of overflowing minutes")
    func testFormattedSpanIncludesHours() {
        let transcript = fixture(entryTexts: ["only"], entrySpacing: 8_130)  // 2h 15m 30s
        #expect(transcript.formattedRecordedSpan == "2:15:30")
    }

    @Test("an empty transcript has a zero span rather than a negative one")
    func testEmptySpanIsZero() {
        let transcript = MeetingTranscript()
        #expect(transcript.recordedSpan == 0)
    }

    // MARK: - Listing

    @Test("list includes a saved session with its entry count and span")
    func testListIncludesSavedSession() throws {
        let transcript = fixture(offsetSeconds: 10)
        let url = try #require(TranscriptStore.save(transcript))
        defer { try? FileManager.default.removeItem(at: url) }

        let summary = try #require(TranscriptStore.list().first { $0.url == url })
        #expect(summary.entryCount == 2)
        #expect(summary.span == 60)  // entries at +30 and +60
        #expect(summary.preview == "First line")
        #expect(summary.title == nil)
    }

    @Test("list is ordered newest first")
    func testListIsNewestFirst() throws {
        let older = try #require(TranscriptStore.save(fixture(offsetSeconds: 100)))
        defer { try? FileManager.default.removeItem(at: older) }
        let newer = try #require(TranscriptStore.save(fixture(offsetSeconds: 200)))
        defer { try? FileManager.default.removeItem(at: newer) }

        let urls = TranscriptStore.list().map(\.url)
        let olderIndex = try #require(urls.firstIndex(of: older))
        let newerIndex = try #require(urls.firstIndex(of: newer))
        #expect(newerIndex < olderIndex)
    }

    // MARK: - Loading

    @Test("load returns the transcript that was written")
    func testLoadRoundTrip() throws {
        let url = try #require(TranscriptStore.save(fixture(offsetSeconds: 300)))
        defer { try? FileManager.default.removeItem(at: url) }

        let loaded = try #require(TranscriptStore.load(url))
        #expect(loaded.entries.count == 2)
        #expect(loaded.entries[0].text == "First line")
        #expect(loaded.entries[1].speaker == .others(speakerIndex: nil))
    }

    @Test("load returns nil for a file that is not a transcript")
    func testLoadRejectsGarbage() throws {
        let url = TranscriptStore.directory
            .appendingPathComponent("meeting-2000-01-01_00-00-00-garbage.json")
        try FileManager.default.createDirectory(
            at: TranscriptStore.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(TranscriptStore.load(url) == nil)
        // A damaged file must not hide the rest of the history.
        #expect(!TranscriptStore.list().contains { $0.url == url })
    }

    // MARK: - Renaming

    @Test("rename stores the title and slugs it into the filename")
    func testRenameSetsTitleAndSlug() throws {
        let original = try #require(TranscriptStore.save(fixture(offsetSeconds: 400)))
        var finalURL = original
        defer { try? FileManager.default.removeItem(at: finalURL) }

        finalURL = try #require(TranscriptStore.rename(original, to: "Sprint Review!"))

        #expect(finalURL.lastPathComponent.hasPrefix("meeting-"))
        #expect(finalURL.lastPathComponent.contains("sprint-review"))
        #expect(finalURL.lastPathComponent.hasSuffix(".json"))

        let reloaded = try #require(TranscriptStore.load(finalURL))
        #expect(reloaded.title == "Sprint Review!")

        let summary = try #require(TranscriptStore.list().first { $0.url == finalURL })
        #expect(summary.displayName == "Sprint Review!")
    }

    @Test("rename to nil clears the title and reverts to the date")
    func testRenameClearsTitle() throws {
        let original = try #require(TranscriptStore.save(fixture(offsetSeconds: 500)))
        var finalURL = try #require(TranscriptStore.rename(original, to: "Temporary"))
        defer { try? FileManager.default.removeItem(at: finalURL) }

        finalURL = try #require(TranscriptStore.rename(finalURL, to: nil))

        let reloaded = try #require(TranscriptStore.load(finalURL))
        #expect(reloaded.title == nil)

        let summary = try #require(TranscriptStore.list().first { $0.url == finalURL })
        // Falls back to a formatted date, which is never the cleared title.
        #expect(summary.displayName != "Temporary")
    }

    @Test("rename treats whitespace as clearing the title")
    func testRenameWhitespaceClearsTitle() throws {
        let original = try #require(TranscriptStore.save(fixture(offsetSeconds: 600)))
        var finalURL = try #require(TranscriptStore.rename(original, to: "Named"))
        defer { try? FileManager.default.removeItem(at: finalURL) }

        finalURL = try #require(TranscriptStore.rename(finalURL, to: "   "))
        let reloaded = try #require(TranscriptStore.load(finalURL))
        #expect(reloaded.title == nil)
    }

    // MARK: - Deleting

    @Test("delete removes the file and it drops out of the listing")
    func testDeleteRemovesSession() throws {
        let url = try #require(TranscriptStore.save(fixture(offsetSeconds: 700)))

        #expect(TranscriptStore.delete(url))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!TranscriptStore.list().contains { $0.url == url })
    }

    @Test("delete reports failure for a file that is not there")
    func testDeleteMissingFileFails() {
        let missing = TranscriptStore.directory
            .appendingPathComponent("meeting-2000-01-01_00-00-00-absent.json")
        #expect(!TranscriptStore.delete(missing))
    }

    // MARK: - Speaker names

    @Test("a named speaker replaces the generated label")
    func testSetNameOverridesDisplayName() {
        var transcript = fixture()
        let speaker = MeetingSpeaker.others(speakerIndex: 1)

        #expect(transcript.displayName(for: speaker) == "Speaker 2")
        transcript.setName("Danilo", for: speaker)
        #expect(transcript.displayName(for: speaker) == "Danilo")
    }

    @Test("clearing a speaker name falls back to the generated label")
    func testClearingSpeakerName() {
        var transcript = fixture()
        let speaker = MeetingSpeaker.you

        transcript.setName("Gabriel", for: speaker)
        #expect(transcript.displayName(for: speaker) == "Gabriel")

        transcript.setName("   ", for: speaker)
        #expect(transcript.displayName(for: speaker) == "You")
        #expect(transcript.speakerNames["you"] == nil)
    }

    @Test("speaker names are keyed per diarization index, not shared")
    func testNamesArePerSpeaker() {
        var transcript = fixture()
        transcript.setName("Ana", for: .others(speakerIndex: 0))
        transcript.setName("Bruno", for: .others(speakerIndex: 1))

        #expect(transcript.displayName(for: .others(speakerIndex: 0)) == "Ana")
        #expect(transcript.displayName(for: .others(speakerIndex: 1)) == "Bruno")
        // The unresolved track is a separate identity from any indexed speaker.
        #expect(transcript.displayName(for: .others(speakerIndex: nil)) == "Others")
    }

    @Test("plain text export uses assigned speaker names")
    func testPlainTextUsesNames() {
        var transcript = fixture(entryTexts: ["Hello there"])
        transcript.setName("Gabriel", for: .you)

        let text = transcript.asPlainText()
        #expect(text.contains("Gabriel: Hello there"))
        #expect(!text.contains("You: Hello there"))
    }

    @Test("presentSpeakers lists each speaker once, local first")
    func testPresentSpeakersOrdering() {
        let start = Date(timeIntervalSince1970: 946_684_800)
        var transcript = MeetingTranscript(startTime: start)
        transcript.entries = [
            MeetingTranscriptEntry(speaker: .others(speakerIndex: 1), text: "b", timestamp: start),
            MeetingTranscriptEntry(speaker: .you, text: "a", timestamp: start),
            MeetingTranscriptEntry(speaker: .others(speakerIndex: nil), text: "c", timestamp: start),
            MeetingTranscriptEntry(speaker: .others(speakerIndex: 0), text: "d", timestamp: start),
            MeetingTranscriptEntry(speaker: .you, text: "e", timestamp: start),
        ]

        #expect(
            transcript.presentSpeakers == [
                .you,
                .others(speakerIndex: 0),
                .others(speakerIndex: 1),
                .others(speakerIndex: nil),
            ])
    }

    @Test("speaker names survive a save and reload")
    func testSpeakerNamesPersist() throws {
        var transcript = fixture(offsetSeconds: 800)
        transcript.setName("Danilo", for: .others(speakerIndex: nil))

        let url = try #require(TranscriptStore.save(transcript))
        defer { try? FileManager.default.removeItem(at: url) }

        let reloaded = try #require(TranscriptStore.load(url))
        #expect(reloaded.displayName(for: .others(speakerIndex: nil)) == "Danilo")
    }

    @Test("a transcript written before speaker names existed still decodes")
    func testLegacyTranscriptWithoutSpeakerNamesDecodes() throws {
        // Exactly the shape older builds wrote: no speakerNames, no title.
        let legacy = """
            {
              "entries" : [
                {
                  "id" : "\(UUID().uuidString)",
                  "speaker" : { "you" : {} },
                  "text" : "Legacy entry",
                  "timestamp" : "2000-01-01T00:00:30Z"
                }
              ],
              "startTime" : "2000-01-01T00:00:00Z"
            }
            """

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transcript = try decoder.decode(
            MeetingTranscript.self, from: Data(legacy.utf8))

        #expect(transcript.entries.count == 1)
        #expect(transcript.title == nil)
        #expect(transcript.speakerNames.isEmpty)
        #expect(transcript.displayName(for: .you) == "You")
    }
}
