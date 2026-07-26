//
//  MeetingHistoryStoreTests.swift
//  wisprTests
//
//  Covers browsing past transcripts: selection, the live/archived separation
//  that protects a transcript being read from a new meeting, rename write-back,
//  and deletion.
//

import Foundation
import Testing

@testable import WisprApp

@MainActor
@Suite("MeetingHistoryStore Tests", .serialized)
struct MeetingHistoryStoreTests {

    /// Runs `body` and deletes every transcript it created, so the suite leaves
    /// the real transcripts directory as it found it.
    private func withCleanup(_ body: (inout [URL]) async throws -> Void) async throws {
        var created: [URL] = []
        do {
            try await body(&created)
        } catch {
            for url in created { try? TranscriptStore.delete(url) }
            throw error
        }
        for url in created { try? TranscriptStore.delete(url) }
    }

    private func saveTranscript(
        start: Date = Date(),
        texts: [String] = ["hello"],
        speakerIndex: Int? = nil
    ) throws -> URL {
        var transcript = MeetingTranscript(startTime: start)
        for (i, text) in texts.enumerated() {
            transcript.entries.append(
                MeetingTranscriptEntry(
                    speaker: speakerIndex.map { .others(speakerIndex: $0) } ?? .you,
                    text: text,
                    timestamp: start.addingTimeInterval(Double(i + 1))
                )
            )
        }
        return try #require(TranscriptStore.save(transcript))
    }

    // MARK: - Initial state

    @Test("Starts on the live session with nothing loaded")
    func testInitialState() {
        let store = MeetingHistoryStore()

        #expect(store.selection == .live)
        #expect(store.loadedTranscript == nil)
        #expect(store.isShowingArchived == false)
        #expect(store.loadedURL == nil)
        #expect(store.errorMessage == nil)
    }

    // MARK: - Listing and selection

    @Test("refresh() picks up saved transcripts")
    func testRefreshFindsSaved() async throws {
        try await withCleanup { created in
            created.append(try saveTranscript(texts: ["retrouvé"]))

            let store = MeetingHistoryStore()
            await store.refresh()

            #expect(store.summaries.contains { created.contains($0.url) })
            #expect(store.isLoading == false)
        }
    }

    @Test("Selecting an archived transcript loads it and switches away from live")
    func testShowArchived() async throws {
        try await withCleanup { created in
            let url = try saveTranscript(texts: ["archivé"])
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            let summary = try #require(store.summaries.first { $0.url == url })

            await store.show(summary)

            #expect(store.selection == .archived(url))
            #expect(store.isShowingArchived)
            #expect(store.loadedURL == url)
            #expect(store.loadedTranscript?.entries.first?.text == "archivé")
        }
    }

    @Test("showLive() returns to the live session and releases the archive")
    func testShowLive() async throws {
        try await withCleanup { created in
            let url = try saveTranscript()
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            await store.show(try #require(store.summaries.first { $0.url == url }))

            store.showLive()

            #expect(store.selection == .live)
            #expect(store.loadedTranscript == nil)
            #expect(store.isShowingArchived == false)
        }
    }

    @Test("An unreadable transcript is selectable but surfaces an error")
    func testUnreadableSelection() async throws {
        try await withCleanup { created in
            // The file must match the store's naming convention to be listed.
            let corrupt = TranscriptStore.directory
                .appendingPathComponent("meeting-9998-01-01_00-00-00.json")
            try FileManager.default.createDirectory(
                at: TranscriptStore.directory, withIntermediateDirectories: true)
            try Data("garbage".utf8).write(to: corrupt)
            created.append(corrupt)

            let store = MeetingHistoryStore()
            await store.refresh()
            let summary = try #require(store.summaries.first { $0.url == corrupt })
            #expect(summary.isUnreadable)

            await store.show(summary)

            // Selected (so it can be deleted) but nothing loaded, and the user is told.
            #expect(store.selection == .archived(corrupt))
            #expect(store.loadedTranscript == nil)
            #expect(store.errorMessage != nil)
        }
    }

    @Test("A transcript deleted behind the app's back falls back to live")
    func testStaleSelectionFallsBackToLive() async throws {
        try await withCleanup { created in
            let url = try saveTranscript()
            let store = MeetingHistoryStore()
            await store.refresh()
            await store.show(try #require(store.summaries.first { $0.url == url }))
            #expect(store.isShowingArchived)

            // Removed outside the store, as another window or Finder would.
            try TranscriptStore.delete(url)
            await store.refresh()

            #expect(store.selection == .live)
            #expect(store.loadedTranscript == nil)
            _ = created
        }
    }

    // MARK: - The live/archived separation

    @Test("A new meeting does not disturb the archived transcript being read")
    func testNewMeetingDoesNotClobberArchive() async throws {
        try await withCleanup { created in
            let url = try saveTranscript(texts: ["ancien contenu"])
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            await store.show(try #require(store.summaries.first { $0.url == url }))

            // startMeeting() assigns a fresh MeetingTranscript to the state
            // manager. Before the live/archived split this reset was what the
            // view rendered, so it destroyed the transcript on screen.
            let manager = createTestMeetingStateManager()
            manager.transcript = MeetingTranscript()

            #expect(store.loadedTranscript?.entries.first?.text == "ancien contenu")
            #expect(store.isShowingArchived)
        }
    }

    // MARK: - Rename

    @Test("Renaming an archived speaker persists to that same file")
    func testRenamePersists() async throws {
        try await withCleanup { created in
            let url = try saveTranscript(texts: ["bonjour"], speakerIndex: 0)
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            await store.show(try #require(store.summaries.first { $0.url == url }))

            await store.renameSpeaker(index: 0, to: "Alice")

            #expect(store.errorMessage == nil)
            #expect(store.loadedTranscript?.displayName(for: .others(speakerIndex: 0)) == "Alice")
            // Written through, not just held in memory.
            #expect(try TranscriptStore.load(url).speakerNames == ["0": "Alice"])
            // And no second file was created.
            #expect(store.summaries.filter { $0.url == url }.count == 1)
        }
    }

    @Test("A rename updates the name shown in the sidebar")
    func testRenameRefreshesSummaries() async throws {
        try await withCleanup { created in
            let url = try saveTranscript(texts: ["salut"], speakerIndex: 0)
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            await store.show(try #require(store.summaries.first { $0.url == url }))
            #expect(store.summaries.first { $0.url == url }?.speakerNames == ["Speaker 1"])

            await store.renameSpeaker(index: 0, to: "Bob")

            #expect(store.summaries.first { $0.url == url }?.speakerNames == ["Bob"])
        }
    }

    @Test("Renaming while showing the live session is a no-op on disk")
    func testRenameIgnoredWhenLive() async throws {
        try await withCleanup { created in
            let url = try saveTranscript(texts: ["intact"], speakerIndex: 0)
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            // Never selected an archive — the live transcript is owned by
            // MeetingStateManager, not by this store.
            await store.renameSpeaker(index: 0, to: "Alice")

            #expect(try TranscriptStore.load(url).speakerNames.isEmpty)
        }
    }

    // MARK: - Delete

    @Test("Deleting removes the file and drops it from the list")
    func testDelete() async throws {
        let url = try saveTranscript()

        let store = MeetingHistoryStore()
        await store.refresh()
        let summary = try #require(store.summaries.first { $0.url == url })

        await store.delete(summary)

        #expect(store.errorMessage == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!store.summaries.contains { $0.url == url })
    }

    @Test("Deleting the transcript on screen returns the view to live")
    func testDeleteCurrentReturnsToLive() async throws {
        let url = try saveTranscript()

        let store = MeetingHistoryStore()
        await store.refresh()
        let summary = try #require(store.summaries.first { $0.url == url })
        await store.show(summary)
        #expect(store.isShowingArchived)

        await store.delete(summary)

        #expect(store.selection == .live)
        #expect(store.loadedTranscript == nil)
    }

    @Test("A failed delete surfaces an error instead of failing silently")
    func testDeleteFailureSurfaces() async {
        let missing = TranscriptStore.directory
            .appendingPathComponent("meeting-1970-01-01_00-00-01.json")
        let summary = TranscriptSummary(
            url: missing, startTime: Date(), duration: 0, entryCount: 0,
            speakerNames: [], preview: "", isUnreadable: false)

        let store = MeetingHistoryStore()
        await store.delete(summary)

        #expect(store.errorMessage != nil)
    }

    @Test("dismissError clears a surfaced message")
    func testDismissError() async {
        let store = MeetingHistoryStore()
        let missing = TranscriptStore.directory
            .appendingPathComponent("meeting-1970-01-01_00-00-02.json")
        await store.delete(
            TranscriptSummary(
                url: missing, startTime: Date(), duration: 0, entryCount: 0,
                speakerNames: [], preview: "", isUnreadable: false))
        #expect(store.errorMessage != nil)

        store.dismissError()

        #expect(store.errorMessage == nil)
    }
}

// MARK: - Live rename

@MainActor
@Suite("MeetingStateManager Rename Tests", .serialized)
struct MeetingStateManagerRenameTests {

    @Test("Renaming relabels the speaker's existing entries")
    func testRenameLive() {
        let manager = createTestMeetingStateManager()
        for text in ["un", "deux"] {
            manager.transcript.entries.append(
                MeetingTranscriptEntry(speaker: .others(speakerIndex: 0), text: text))
        }

        manager.renameSpeaker(index: 0, to: "Alice")

        for entry in manager.transcript.entries {
            #expect(manager.transcript.displayName(for: entry.speaker) == "Alice")
        }
    }

    @Test("Entries arriving after a rename inherit the name")
    func testRenameAppliesToLaterEntries() {
        let manager = createTestMeetingStateManager()
        manager.renameSpeaker(index: 0, to: "Alice")

        manager.transcript.entries.append(
            MeetingTranscriptEntry(speaker: .others(speakerIndex: 0), text: "après"))

        #expect(
            manager.transcript.displayName(for: .others(speakerIndex: 0)) == "Alice")
    }

    @Test("Clearing a name restores the generic label")
    func testClearName() {
        let manager = createTestMeetingStateManager()
        manager.renameSpeaker(index: 0, to: "Alice")

        manager.renameSpeaker(index: 0, to: "")

        #expect(
            manager.transcript.displayName(for: .others(speakerIndex: 0)) == "Speaker 1")
    }
}
