//
//  TranscriptExportCoordinatorTests.swift
//  wisprTests
//
//  Covers when a saved meeting is exported and that a failing export stays contained.
//

import Foundation
import Synchronization
import Testing

@testable import WisprApp

@MainActor
private final class RecordingNotifier: TranscriptExportNotifying {
    private(set) var failures: [(destination: TranscriptExportDestination, message: String)] = []

    func exportFailed(destination: TranscriptExportDestination, message: String) {
        failures.append((destination, message))
    }
}

/// Counts how many times the coordinator asked for a file to be written.
private nonisolated final class ExportCalls: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func record() { value.withLock { $0 += 1 } }
}

@MainActor
@Suite("Transcript export coordinator Tests")
struct TranscriptExportCoordinatorTests {

    private let obsidianInstalled = FakeAppInstallDetector(installed: ["md.obsidian"])

    private func makeSettings(enabled: Bool = true, bookmark: Data? = Data([1])) -> SettingsStore {
        let settings = SettingsStore(
            defaults: UserDefaults(suiteName: "test.wispr.coordinator.\(UUID().uuidString)")!)
        settings.updateExportConfig(for: .obsidian) {
            $0.enabled = enabled
            $0.folderBookmark = bookmark
        }
        return settings
    }

    private func makeTranscript() -> MeetingTranscript {
        var transcript = MeetingTranscript(startTime: Date())
        transcript.entries = [MeetingTranscriptEntry(speaker: .you, text: "Hi")]
        return transcript
    }

    private func makeCoordinator(
        settings: SettingsStore,
        detector: FakeAppInstallDetector,
        notifier: RecordingNotifier,
        calls: ExportCalls,
        result: Result<TranscriptExporter.Result, any Error>
    ) -> TranscriptExportCoordinator {
        TranscriptExportCoordinator(
            settings: settings, detector: detector, notifier: notifier,
            export: { _, _ in
                calls.record()
                return try result.get()
            })
    }

    private let success = Result<TranscriptExporter.Result, any Error>.success(
        .init(url: URL(fileURLWithPath: "/tmp/x.md"), refreshedBookmark: nil))

    @Test("An enabled, installed destination with a folder is exported to")
    func testExports() {
        let calls = ExportCalls()
        let coordinator = makeCoordinator(
            settings: makeSettings(), detector: obsidianInstalled,
            notifier: RecordingNotifier(), calls: calls, result: success)
        coordinator.exportIfConfigured(makeTranscript())
        #expect(calls.count == 1)
    }

    @Test("Nothing is exported when the destination is switched off")
    func testDisabled() {
        let calls = ExportCalls()
        let coordinator = makeCoordinator(
            settings: makeSettings(enabled: false), detector: obsidianInstalled,
            notifier: RecordingNotifier(), calls: calls, result: success)
        coordinator.exportIfConfigured(makeTranscript())
        #expect(calls.count == 0)
    }

    @Test("Nothing is exported when the app is not installed")
    func testNotInstalled() {
        let calls = ExportCalls()
        let coordinator = makeCoordinator(
            settings: makeSettings(), detector: FakeAppInstallDetector(installed: []),
            notifier: RecordingNotifier(), calls: calls, result: success)
        coordinator.exportIfConfigured(makeTranscript())
        #expect(calls.count == 0)
    }

    @Test("Nothing is exported when no folder has been chosen")
    func testNoFolder() {
        let calls = ExportCalls()
        let coordinator = makeCoordinator(
            settings: makeSettings(bookmark: nil), detector: obsidianInstalled,
            notifier: RecordingNotifier(), calls: calls, result: success)
        coordinator.exportIfConfigured(makeTranscript())
        #expect(calls.count == 0)
    }

    @Test("A failing export is reported and does not throw")
    func testFailureIsContained() {
        let notifier = RecordingNotifier()
        let settings = makeSettings()
        let coordinator = makeCoordinator(
            settings: settings, detector: obsidianInstalled, notifier: notifier,
            calls: ExportCalls(), result: .failure(CocoaError(.fileWriteOutOfSpace)))

        coordinator.exportIfConfigured(makeTranscript())

        #expect(notifier.failures.count == 1)
        #expect(notifier.failures.first?.destination == .obsidian)
        #expect(settings.exportConfig(for: .obsidian).folderUnavailable == false)
    }

    @Test("An unavailable folder is flagged so Settings can ask for it again")
    func testFolderUnavailableFlag() {
        let settings = makeSettings()
        let coordinator = makeCoordinator(
            settings: settings, detector: obsidianInstalled, notifier: RecordingNotifier(),
            calls: ExportCalls(), result: .failure(TranscriptExporter.ExportError.folderUnavailable("gone")))

        coordinator.exportIfConfigured(makeTranscript())
        #expect(settings.exportConfig(for: .obsidian).folderUnavailable)
    }

    @Test("A refreshed bookmark replaces the stored one and clears the flag")
    func testRefreshedBookmark() {
        let settings = makeSettings()
        settings.updateExportConfig(for: .obsidian) { $0.folderUnavailable = true }
        let refreshed = Result<TranscriptExporter.Result, any Error>.success(
            .init(url: URL(fileURLWithPath: "/tmp/x.md"), refreshedBookmark: Data([9])))
        let coordinator = makeCoordinator(
            settings: settings, detector: obsidianInstalled, notifier: RecordingNotifier(),
            calls: ExportCalls(), result: refreshed)

        coordinator.exportIfConfigured(makeTranscript())

        let config = settings.exportConfig(for: .obsidian)
        #expect(config.folderBookmark == Data([9]))
        #expect(config.folderUnavailable == false)
    }
}
