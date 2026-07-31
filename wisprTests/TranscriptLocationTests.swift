//
//  TranscriptLocationTests.swift
//  wisprTests
//
//  Covers the configurable transcripts folder: bookmark round-trip, the fallback
//  that keeps transcripts reachable when a saved folder cannot be used, and the
//  fact that `TranscriptStore` follows the configured location.
//

import Foundation
import Testing

@testable import WisprApp

@Suite("TranscriptLocation Tests", .serialized, .transcriptDirectoryIsolated)
struct TranscriptLocationTests {

    /// Runs `body` with a throwaway folder, always returning the process to the
    /// default location so a failure here cannot redirect another suite's writes.
    ///
    /// Held under `TestTranscriptDirectoryLock`: the location is process-wide, so
    /// redirecting it while another suite is listing transcripts makes that suite
    /// scan this temporary folder and report its own files as missing.
    private func withTemporaryFolder(_ body: (URL) throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-location-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        defer {
            TranscriptLocation.useDefault()
            try? FileManager.default.removeItem(at: folder)
        }
        try body(folder)
    }

    @Test("Defaults to the app container")
    func testDefaultLocation() async {
        TranscriptLocation.useDefault()

        #expect(TranscriptLocation.isCustom == false)
        #expect(TranscriptLocation.current == TranscriptLocation.defaultDirectory)
        #expect(TranscriptStore.directory == TranscriptLocation.defaultDirectory)
    }

    @Test("A bookmark round-trips into the current folder")
    func testBookmarkRoundTrip() async throws {
        try await withTemporaryFolder { folder in
            let bookmark = try TranscriptLocation.makeBookmark(for: folder)

            switch TranscriptLocation.activate(bookmark: bookmark) {
            case .activated(let resolved, _):
                // Compare resolved paths: /var is a symlink to /private/var, so the
                // URL that comes back is not string-equal to the one going in.
                #expect(resolved.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
            case .failed(let reason):
                Issue.record("Expected activation to succeed, got: \(reason)")
            }

            #expect(TranscriptLocation.isCustom)
        }
    }

    @Test("TranscriptStore writes into the configured folder")
    func testStoreFollowsLocation() async throws {
        try await withTemporaryFolder { folder in
            let bookmark = try TranscriptLocation.makeBookmark(for: folder)
            guard case .activated = TranscriptLocation.activate(bookmark: bookmark) else {
                Issue.record("Could not activate the temporary folder")
                return
            }

            var transcript = MeetingTranscript(startTime: Date())
            transcript.entries.append(
                MeetingTranscriptEntry(speaker: .you, text: "ailleurs", timestamp: Date()))

            let saved = try #require(TranscriptStore.save(transcript))

            #expect(
                saved.deletingLastPathComponent().resolvingSymlinksInPath()
                    == folder.resolvingSymlinksInPath()
            )
            // The history list must read from the same place it writes to.
            #expect(TranscriptStore.list().contains { $0.url == saved })
        }
    }

    @Test("Garbage bookmark data falls back to the default folder")
    func testCorruptBookmarkFallsBack() {
        defer { TranscriptLocation.useDefault() }

        // Writing transcripts to an unresolvable location would lose them outright,
        // so an unusable bookmark has to fail back rather than be held onto.
        let outcome = TranscriptLocation.activate(bookmark: Data("not a bookmark".utf8))

        if case .activated = outcome {
            Issue.record("Corrupt bookmark should not activate")
        }
        #expect(TranscriptLocation.isCustom == false)
        #expect(TranscriptStore.directory == TranscriptLocation.defaultDirectory)
    }

    @Test("A bookmark for a deleted folder falls back to the default folder")
    func testDeletedFolderFallsBack() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-gone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let bookmark = try TranscriptLocation.makeBookmark(for: folder)
        try FileManager.default.removeItem(at: folder)

        defer { TranscriptLocation.useDefault() }

        // A bookmark to a removed folder either fails to resolve or resolves stale;
        // either way transcripts must not silently go missing.
        if case .activated(let resolved, _) = TranscriptLocation.activate(bookmark: bookmark) {
            // Resolution succeeded by recreating the path — acceptable, as long as
            // the folder is actually usable.
            #expect(FileManager.default.fileExists(atPath: resolved.path))
        } else {
            #expect(TranscriptStore.directory == TranscriptLocation.defaultDirectory)
        }
    }

    @Test("useDefault() returns to the container after a custom folder")
    func testUseDefaultReleasesCustomFolder() async throws {
        try await withTemporaryFolder { folder in
            let bookmark = try TranscriptLocation.makeBookmark(for: folder)
            _ = TranscriptLocation.activate(bookmark: bookmark)
            #expect(TranscriptLocation.isCustom)

            TranscriptLocation.useDefault()

            #expect(TranscriptLocation.isCustom == false)
            #expect(TranscriptStore.directory == TranscriptLocation.defaultDirectory)
        }
    }

    @MainActor
    @Test("A stored bookmark that cannot be used is cleared from settings")
    func testUnusableStoredBookmarkIsCleared() {
        defer { TranscriptLocation.useDefault() }

        let defaults = UserDefaults(suiteName: "TranscriptLocationTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)
        settings.transcriptsFolderBookmark = Data("not a bookmark".utf8)

        let message = TranscriptLocation.applyStoredFolder(from: settings)

        // Left in place, the app would retry an unresolvable folder on every launch
        // and keep surfacing the same warning.
        #expect(message != nil)
        #expect(settings.transcriptsFolderBookmark == nil)
        #expect(TranscriptLocation.isCustom == false)
    }

    @MainActor
    @Test("No stored bookmark leaves the default folder in force")
    func testNoStoredBookmark() {
        let defaults = UserDefaults(suiteName: "TranscriptLocationTests-\(UUID().uuidString)")!
        let settings = SettingsStore(defaults: defaults)

        let message = TranscriptLocation.applyStoredFolder(from: settings)

        #expect(message == nil)
        #expect(TranscriptLocation.isCustom == false)
    }

    @MainActor
    @Test("The chosen folder survives a SettingsStore reload")
    func testBookmarkPersists() async throws {
        let suite = "TranscriptLocationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        try await withTemporaryFolder { folder in
            let bookmark = try TranscriptLocation.makeBookmark(for: folder)
            let settings = SettingsStore(defaults: defaults)
            settings.transcriptsFolderBookmark = bookmark

            // A path string would be useless here: what has to survive is the
            // sandbox grant, which only the bookmark carries.
            let reloaded = SettingsStore(defaults: defaults)
            #expect(reloaded.transcriptsFolderBookmark == bookmark)
        }
    }

    // MARK: - Change notification

    @Test("Changing the folder is broadcast to listeners")
    func testChangeIsBroadcast() async throws {
        // Summaries are keyed by file URL, so a listener that misses this keeps
        // pointing every action — open, reveal in Finder, delete — at the old folder.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-broadcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            TranscriptLocation.useDefault()
            try? FileManager.default.removeItem(at: folder)
        }

        let bookmark = try TranscriptLocation.makeBookmark(for: folder)

        let received = await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await directory in TranscriptLocation.changes() { return directory }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                _ = TranscriptLocation.activate(bookmark: bookmark)
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }

            for await value in group where value != nil {
                group.cancelAll()
                return value
            }
            return nil
        }

        let directory = try #require(received)
        #expect(directory.resolvingSymlinksInPath() == folder.resolvingSymlinksInPath())
    }

    @Test("Returning to the default folder is broadcast too")
    func testReturnToDefaultIsBroadcast() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-broadcast-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer {
            TranscriptLocation.useDefault()
            try? FileManager.default.removeItem(at: folder)
        }

        let bookmark = try TranscriptLocation.makeBookmark(for: folder)
        _ = TranscriptLocation.activate(bookmark: bookmark)

        let received = await withTaskGroup(of: URL?.self) { group in
            group.addTask {
                for await directory in TranscriptLocation.changes() { return directory }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(200))
                // Dropping a custom folder moves transcripts back to the container,
                // which is a change even though the new scope is nil.
                TranscriptLocation.useDefault()
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }

            for await value in group where value != nil {
                group.cancelAll()
                return value
            }
            return nil
        }

        #expect(try #require(received) == TranscriptLocation.defaultDirectory)
    }
}
