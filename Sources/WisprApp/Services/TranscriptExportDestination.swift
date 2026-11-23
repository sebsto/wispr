//
//  TranscriptExportDestination.swift
//  wispr
//
//  The note-taking apps meeting transcripts can be exported to, and how to tell
//  which of them are installed on this Mac.
//

import AppKit
import Foundation

/// Answers whether an app is installed, so detection can be faked in tests.
nonisolated protocol AppInstallDetecting: Sendable {
    func isInstalled(bundleIdentifier: String) -> Bool
}

/// Asks Launch Services whether an app with the given bundle identifier exists.
nonisolated struct WorkspaceAppInstallDetector: AppInstallDetecting {
    func isInstalled(bundleIdentifier: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) != nil
    }
}

/// A note-taking app that receives a Markdown copy of each saved meeting transcript.
///
/// Every destination gets its own settings, stored under `id`, and is offered in
/// Settings only while its app is installed. Supporting another app means adding
/// one entry to `all`; the Markdown output and the Settings layout are shared.
nonisolated struct TranscriptExportDestination: Identifiable, Hashable, Sendable {
    /// Stable key for the destination's stored settings. Never changes once shipped.
    let id: String
    /// Name shown in Settings, for example "Obsidian".
    let displayName: String
    /// Bundle identifier used to detect whether the app is installed.
    let bundleIdentifier: String

    static let obsidian = TranscriptExportDestination(
        id: "obsidian",
        displayName: "Obsidian",
        bundleIdentifier: "md.obsidian"
    )

    /// Every destination Wispr knows about, installed or not.
    static let all: [TranscriptExportDestination] = [obsidian]

    /// The known destinations whose app is installed.
    static func detected(
        using detector: any AppInstallDetecting = WorkspaceAppInstallDetector()
    ) -> [TranscriptExportDestination] {
        all.filter { detector.isInstalled(bundleIdentifier: $0.bundleIdentifier) }
    }
}

/// One destination's export settings.
nonisolated struct TranscriptExportConfig: Codable, Equatable, Sendable {
    /// Whether saved meetings are copied to this destination. Off until the user opts in.
    var enabled = false
    /// Security-scoped bookmark for the folder the user picked, or `nil` when none is set.
    var folderBookmark: Data?
    /// Optional folder inside the chosen one, created when missing. Empty means none.
    var subfolder = ""
    /// Whether each file starts with a YAML properties block.
    var includeFrontmatter = true
    /// Set when the last export could not open the saved folder, so Settings can ask
    /// the user to choose it again. Cleared by the next successful export or a new pick.
    var folderUnavailable = false
}
