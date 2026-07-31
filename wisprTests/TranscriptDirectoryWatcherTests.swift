//
//  TranscriptDirectoryWatcherTests.swift
//  wisprTests
//
//  Covers the folder watch that keeps the meeting history in step with files
//  deleted or added outside the app.
//

import Foundation
import Testing

@testable import WisprApp

@Suite("TranscriptDirectoryWatcher Tests", .serialized)
struct TranscriptDirectoryWatcherTests {

    private func withTemporaryFolder(_ body: (URL) async throws -> Void) async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try await body(folder)
    }

    /// Waits for the watcher's first event, or gives up.
    ///
    /// Bounded so a watcher that never fires fails the test instead of hanging the
    /// suite forever.
    private func firstEvent(
        in folder: URL,
        triggeredBy change: @escaping @Sendable () -> Void
    ) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in TranscriptDirectoryWatcher.changes(for: folder) {
                    return true
                }
                return false
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return false
            }
            group.addTask {
                // Give the source time to arm before touching the folder, otherwise
                // the change can land before anything is listening.
                try? await Task.sleep(for: .milliseconds(200))
                change()
                return false
            }

            // The first `true` wins; the timeout arm returns false.
            for await fired in group where fired {
                group.cancelAll()
                return true
            }
            return false
        }
    }

    @Test("A file appearing in the folder is reported")
    func testDetectsCreation() async throws {
        try await withTemporaryFolder { folder in
            let file = folder.appendingPathComponent("meeting-2026-01-01_00-00-00.json")

            let fired = await firstEvent(in: folder) {
                try? Data("{}".utf8).write(to: file)
            }

            #expect(fired)
        }
    }

    @Test("A file deleted outside the app is reported")
    func testDetectsExternalDeletion() async throws {
        try await withTemporaryFolder { folder in
            // This is the case that motivates the watcher: deleting a transcript in
            // Finder used to leave a dead row in the history sidebar.
            let file = folder.appendingPathComponent("meeting-2026-01-01_00-00-01.json")
            try Data("{}".utf8).write(to: file)

            let fired = await firstEvent(in: folder) {
                try? FileManager.default.removeItem(at: file)
            }

            #expect(fired)
        }
    }

    @Test("A file renamed outside the app is reported")
    func testDetectsExternalRename() async throws {
        try await withTemporaryFolder { folder in
            let original = folder.appendingPathComponent("meeting-2026-01-01_00-00-02.json")
            let renamed = folder.appendingPathComponent("meeting-2026-01-01_00-00-02-retro.json")
            try Data("{}".utf8).write(to: original)

            let fired = await firstEvent(in: folder) {
                try? FileManager.default.moveItem(at: original, to: renamed)
            }

            #expect(fired)
        }
    }

    @Test("Watching a folder that does not exist yet creates it rather than failing")
    func testCreatesMissingFolder() async throws {
        // A fresh install has no transcripts folder, and opening a missing path
        // fails outright — the watcher has to establish it first.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wispr-watch-missing-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        let stream = TranscriptDirectoryWatcher.changes(for: folder)

        #expect(FileManager.default.fileExists(atPath: folder.path))

        // Consume and cancel so the descriptor behind the stream is released.
        let drain = Task {
            for await _ in stream { break }
        }
        drain.cancel()
        _ = await drain.value
    }
}
