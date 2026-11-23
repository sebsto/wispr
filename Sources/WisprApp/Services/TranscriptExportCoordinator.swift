//
//  TranscriptExportCoordinator.swift
//  wispr
//
//  Decides which export destinations a just-saved meeting goes to, runs the
//  export, and reports failures without ever disturbing the save itself.
//

import Foundation
import UserNotifications
import WisprCore
import os

/// Tells the user that an export failed.
@MainActor
protocol TranscriptExportNotifying: AnyObject {
    func exportFailed(destination: TranscriptExportDestination, message: String)
}

/// Posts a system notification. Failing to notify is logged and otherwise ignored.
@MainActor
final class TranscriptExportNotifier: TranscriptExportNotifying {

    func exportFailed(destination: TranscriptExportDestination, message: String) {
        // Looked up only when a failure needs reporting: the notification center
        // cannot be reached from a process without an app bundle, such as tests.
        let center = UNUserNotificationCenter.current()
        Task {
            _ = try? await center.requestAuthorization(options: [.alert])

            let content = UNMutableNotificationContent()
            content.title = "Could not export to \(destination.displayName)"
            content.body = message
            let request = UNNotificationRequest(
                identifier: "com.stormacq.mac.wispr.export-failed.\(destination.id)",
                content: content,
                trigger: nil)
            do {
                try await center.add(request)
            } catch {
                Log.stateManager.error(
                    "TranscriptExportNotifier — failed to post notification: \(error.localizedDescription)"
                )
            }
        }
    }
}

/// Copies a saved meeting to every destination that is installed, switched on, and
/// has a folder.
///
/// Export is best effort: nothing here throws, so a broken export folder can never
/// affect saving or recording. A failure is logged and reported through `notifier`.
@MainActor
final class TranscriptExportCoordinator {

    private let settings: SettingsStore
    private let detector: any AppInstallDetecting
    private let notifier: any TranscriptExportNotifying
    private let export: @Sendable (MeetingTranscript, TranscriptExportConfig) throws -> TranscriptExporter.Result

    /// - Parameters:
    ///   - detector: Tells which destination apps are installed.
    ///   - notifier: Reports failures to the user.
    ///   - export: Performs the file work; replaced in tests.
    init(
        settings: SettingsStore,
        detector: any AppInstallDetecting = WorkspaceAppInstallDetector(),
        notifier: (any TranscriptExportNotifying)? = nil,
        export: @escaping @Sendable (MeetingTranscript, TranscriptExportConfig) throws ->
            TranscriptExporter.Result = { try TranscriptExporter.export($0, using: $1) }
    ) {
        self.settings = settings
        self.detector = detector
        self.notifier = notifier ?? TranscriptExportNotifier()
        self.export = export
    }

    /// Exports `transcript` to each destination that is ready.
    func exportIfConfigured(_ transcript: MeetingTranscript) {
        for destination in TranscriptExportDestination.detected(using: detector) {
            let config = settings.exportConfig(for: destination)
            guard config.enabled, config.folderBookmark != nil else { continue }
            run(destination: destination, config: config, transcript: transcript)
        }
    }

    private func run(
        destination: TranscriptExportDestination,
        config: TranscriptExportConfig,
        transcript: MeetingTranscript
    ) {
        do {
            let result = try export(transcript, config)
            settings.updateExportConfig(for: destination) {
                if let refreshed = result.refreshedBookmark { $0.folderBookmark = refreshed }
                $0.folderUnavailable = false
            }
            Log.stateManager.debug(
                "TranscriptExportCoordinator — exported to \(destination.id): \(result.url.lastPathComponent)"
            )
        } catch {
            if case TranscriptExporter.ExportError.folderUnavailable = error {
                settings.updateExportConfig(for: destination) { $0.folderUnavailable = true }
            }
            Log.stateManager.error(
                "TranscriptExportCoordinator — export to \(destination.id) failed: \(error.localizedDescription)"
            )
            notifier.exportFailed(
                destination: destination, message: error.localizedDescription)
        }
    }
}
