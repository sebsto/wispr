//
//  TranscriptExportWiringTests.swift
//  wisprTests
//
//  Covers that a meeting is exported exactly once, and only after it was saved,
//  on both the stop path and the app-termination path.
//

import Foundation
import Synchronization
import Testing

@testable import WisprApp

/// Counts export attempts made by the coordinator under test.
private nonisolated final class CountingExport: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func record() { value.withLock { $0 += 1 } }
}

@MainActor
private final class SilentNotifier: TranscriptExportNotifying {
    func exportFailed(destination: TranscriptExportDestination, message: String) {}
}

@MainActor
@Suite("Meeting export wiring Tests", .serialized, .transcriptDirectoryIsolated)
struct TranscriptExportWiringTests {

    private struct Fixture {
        let manager: MeetingStateManager
        let exports: CountingExport
    }

    private func makeFixture() -> Fixture {
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.wiring.\(UUID().uuidString)")!)
        settings.updateExportConfig(for: .obsidian) {
            $0.enabled = true
            $0.folderBookmark = Data([1])
        }
        let exports = CountingExport()
        let coordinator = TranscriptExportCoordinator(
            settings: settings,
            detector: FakeAppInstallDetector(installed: ["md.obsidian"]),
            notifier: SilentNotifier(),
            export: { _, _ in
                exports.record()
                return .init(url: URL(fileURLWithPath: "/tmp/x.md"), refreshedBookmark: nil)
            })
        let manager = MeetingStateManager(
            meetingAudioEngine: MeetingAudioEngine(),
            transcriptionEngine: FakeMeetingTranscriptionEngine(),
            settingsStore: settings,
            exportCoordinator: coordinator)
        return Fixture(manager: manager, exports: exports)
    }

    /// Runs `body` and removes any transcript file it left in the transcripts folder.
    private func discardingSavedFiles(_ body: () async -> Void) async {
        let before = Set(TranscriptStore.list().map(\.url))
        await body()
        for summary in TranscriptStore.list() where !before.contains(summary.url) {
            try? FileManager.default.removeItem(at: summary.url)
        }
    }

    private func addEntry(to manager: MeetingStateManager) {
        manager.meetingState = .recording
        manager.transcript.entries = [MeetingTranscriptEntry(speaker: .you, text: "Hello")]
    }

    @Test("Stopping a meeting with content exports it once")
    func testStopExportsOnce() async {
        let fixture = makeFixture()
        addEntry(to: fixture.manager)

        await discardingSavedFiles { await fixture.manager.stopMeeting() }

        #expect(fixture.exports.count == 1)
    }

    @Test("Stopping a meeting with no content saves nothing and exports nothing")
    func testStopEmptyDoesNotExport() async {
        let fixture = makeFixture()
        fixture.manager.meetingState = .recording

        await fixture.manager.stopMeeting()

        #expect(fixture.manager.lastSavedURL == nil)
        #expect(fixture.exports.count == 0)
    }

    @Test("Quitting during a meeting exports it once")
    func testTerminationExportsOnce() async {
        let fixture = makeFixture()
        addEntry(to: fixture.manager)

        await discardingSavedFiles { fixture.manager.finalizeForTermination() }

        #expect(fixture.exports.count == 1)
    }

    @Test("Quitting with no content exports nothing")
    func testTerminationEmptyDoesNotExport() {
        let fixture = makeFixture()
        fixture.manager.meetingState = .recording

        fixture.manager.finalizeForTermination()

        #expect(fixture.exports.count == 0)
    }

    @Test("Quitting while idle exports nothing")
    func testTerminationIdleDoesNotExport() {
        let fixture = makeFixture()
        fixture.manager.transcript.entries = [MeetingTranscriptEntry(speaker: .you, text: "Hello")]

        fixture.manager.finalizeForTermination()

        #expect(fixture.exports.count == 0)
    }
}
