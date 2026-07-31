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
@Suite("MeetingHistoryStore Tests", .serialized, .transcriptDirectoryIsolated)
struct MeetingHistoryStoreTests {

    /// Runs `body` and deletes every file it registered, so the suite leaves the
    /// real transcripts directory as it found it.
    ///
    /// Tests that rename a file must register the new URL too, since retitling now
    /// moves the file and a URL captured beforehand no longer exists.
    ///
    /// Held under `TestTranscriptDirectoryLock` because other suites share this
    /// directory — one of them redirects it process-wide — and a parallel redirect
    /// would make `refresh()` scan a different folder than the one written to.
    private func withCleanup(_ body: (inout [URL]) async throws -> Void) async throws {
        var created: [URL] = []
        defer { for url in created { try? TranscriptStore.delete(url) } }
        try await body(&created)
    }

    private func saveTranscript(
        start: Date = TestTranscriptClock.nextStart(),
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

    // MARK: - Session title

    @Test("Retitling a session persists and renames the file on disk")
    func testRetitlePersists() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let url = try saveTranscript(start: start, texts: ["bonjour"])
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            let summary = try #require(store.summaries.first { $0.url == url })
            #expect(summary.title == nil)

            await store.retitle(summary, to: "Sprint review")

            #expect(store.errorMessage == nil)

            // Found by start time, not by title: the suites share one real
            // directory, so a title match could land on another session entirely.
            let renamed = try #require(store.summaries.first { $0.startTime == start })
            created.append(renamed.url)
            // The title is the name the user sees in Finder too, so the row is now
            // keyed by a new URL carrying the title.
            #expect(renamed.title == "Sprint review")
            #expect(renamed.url != url)
            #expect(renamed.url.lastPathComponent.contains("Sprint-review"))
            #expect(!FileManager.default.fileExists(atPath: url.path))
            // Written through, not just held in memory.
            #expect(try TranscriptStore.load(renamed.url).title == "Sprint review")
        }
    }

    @Test("A session can be retitled without being opened first")
    func testRetitleWithoutOpening() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let url = try saveTranscript(start: start)
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            // Never selected — renaming happens from the sidebar's context menu.
            #expect(store.isShowingArchived == false)

            await store.retitle(try #require(store.summaries.first { $0.url == url }), to: "Standup")

            let renamed = try #require(store.summaries.first { $0.startTime == start })
            created.append(renamed.url)
            #expect(renamed.title == "Standup")
            #expect(try TranscriptStore.load(renamed.url).title == "Standup")
            #expect(store.isShowingArchived == false)
        }
    }

    @Test("Retitling the open session keeps it open under its new filename")
    func testRetitleUpdatesLoadedTranscript() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let url = try saveTranscript(start: start)
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            let summary = try #require(store.summaries.first { $0.url == url })
            await store.show(summary)

            await store.retitle(summary, to: "Retro")

            // The URL is the row's identity; without remapping the selection, the
            // transcript on screen would look as though it had been deleted.
            let renamed = try #require(store.summaries.first { $0.startTime == start })
            created.append(renamed.url)
            #expect(store.loadedTranscript?.title == "Retro")
            #expect(store.selection == .archived(renamed.url))
            #expect(store.isShowingArchived)
        }
    }

    @Test("Clearing a title falls back to the session's date")
    func testClearTitle() async throws {
        try await withCleanup { created in
            let start = TestTranscriptClock.nextStart()
            let url = try saveTranscript(start: start)
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            await store.retitle(
                try #require(store.summaries.first { $0.url == url }), to: "Temporaire")

            let titled = try #require(store.summaries.first { $0.startTime == start })
            created.append(titled.url)
            #expect(titled.title == "Temporaire")

            await store.retitle(titled, to: nil)

            // Clearing the title also takes it back out of the filename.
            let cleared = try #require(store.summaries.first { $0.url == url })
            #expect(cleared.title == nil)
            #expect(cleared.hasTitle == false)
        }
    }

    @Test("Retitling a missing file surfaces an error")
    func testRetitleFailureSurfaces() async {
        let missing = TranscriptStore.directory
            .appendingPathComponent("meeting-1970-01-01_00-00-03.json")
        let store = MeetingHistoryStore()

        await store.retitle(
            TranscriptSummary(
                url: missing, startTime: Date(), title: nil, duration: 0, entryCount: 0,
                speakerNames: [], preview: "", isUnreadable: false),
            to: "Fantôme")

        #expect(store.errorMessage != nil)
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
            url: missing, startTime: Date(), title: nil, duration: 0, entryCount: 0,
            speakerNames: [], preview: "", isUnreadable: false)

        let store = MeetingHistoryStore()
        await store.delete(summary)

        #expect(store.errorMessage != nil)
    }

    // MARK: - Batch delete

    @Test("Deleting several transcripts removes all of them")
    func testDeleteMany() async throws {
        try await withCleanup { created in
            let urls = [
                try saveTranscript(texts: ["un"]),
                try saveTranscript(texts: ["deux"]),
                try saveTranscript(texts: ["trois"]),
            ]
            created.append(contentsOf: urls)

            let store = MeetingHistoryStore()
            await store.refresh()
            let targets = urls.compactMap { url in store.summaries.first { $0.url == url } }
            #expect(targets.count == 3)

            await store.delete(targets)

            #expect(store.errorMessage == nil)
            for url in urls {
                #expect(!FileManager.default.fileExists(atPath: url.path))
                #expect(!store.summaries.contains { $0.url == url })
            }
        }
    }

    @Test("One unreachable file does not stop the rest of a batch")
    func testDeleteManyContinuesPastFailure() async throws {
        try await withCleanup { created in
            // Aborting halfway would leave the user unable to tell which transcripts
            // actually went, so the batch runs to completion and reports afterwards.
            let real = try saveTranscript(texts: ["réel"])
            created.append(real)
            let missing = TranscriptStore.directory
                .appendingPathComponent("meeting-1970-01-01_00-00-09.json")

            let store = MeetingHistoryStore()
            await store.refresh()
            let realSummary = try #require(store.summaries.first { $0.url == real })
            let ghost = TranscriptSummary(
                url: missing, startTime: Date(), title: nil, duration: 0, entryCount: 0,
                speakerNames: [], preview: "", isUnreadable: false)

            await store.delete([ghost, realSummary])

            #expect(!FileManager.default.fileExists(atPath: real.path))
            #expect(!store.summaries.contains { $0.url == real })
            #expect(store.errorMessage != nil)
        }
    }

    @Test("Deleting a batch containing the open transcript returns the view to live")
    func testDeleteManyIncludingOpenReturnsToLive() async throws {
        try await withCleanup { created in
            let first = try saveTranscript(texts: ["un"])
            let second = try saveTranscript(texts: ["deux"])
            created.append(contentsOf: [first, second])

            let store = MeetingHistoryStore()
            await store.refresh()
            let openSummary = try #require(store.summaries.first { $0.url == second })
            await store.show(openSummary)
            #expect(store.isShowingArchived)

            let targets = [first, second].compactMap { url in
                store.summaries.first { $0.url == url }
            }
            await store.delete(targets)

            #expect(store.selection == .live)
            #expect(store.loadedTranscript == nil)
        }
    }

    @Test("Deleting an empty batch does nothing")
    func testDeleteEmptyBatch() async throws {
        try await withCleanup { created in
            let url = try saveTranscript()
            created.append(url)

            let store = MeetingHistoryStore()
            await store.refresh()
            let before = store.summaries.count

            await store.delete([])

            #expect(store.errorMessage == nil)
            #expect(store.summaries.count == before)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("dismissError clears a surfaced message")
    func testDismissError() async {
        let store = MeetingHistoryStore()
        let missing = TranscriptStore.directory
            .appendingPathComponent("meeting-1970-01-01_00-00-02.json")
        await store.delete(
            TranscriptSummary(
                url: missing, startTime: Date(), title: nil, duration: 0, entryCount: 0,
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
