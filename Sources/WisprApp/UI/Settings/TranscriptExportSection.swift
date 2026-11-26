//
//  TranscriptExportSection.swift
//  wispr
//
//  Settings section for copying saved meeting transcripts to a note-taking app's
//  folder as Markdown.
//

import AppKit
import SwiftUI

/// One "Export to <app>" group per destination found on this Mac.
///
/// Shown by `SettingsView` only when at least one destination is installed.
struct TranscriptExportSection: View {

    /// Hints shared with tests, like `SettingsView.AccessibilityHints`.
    enum AccessibilityHints {
        static let enable =
            "When enabled, each meeting transcript is also saved as a Markdown file in the chosen folder"
        static let chooseFolder = "Choose the folder that receives exported transcripts"
        static let clearFolder = "Stops exporting and forgets the chosen folder"
        static let subfolder = "Optional folder inside the chosen folder to put transcripts in"
        static let chooseSubfolder = "Choose a folder inside the export folder to put transcripts in"
        static let frontmatter =
            "When enabled, each file starts with properties such as title, date, and speakers"
    }

    let destinations: [TranscriptExportDestination]

    @Environment(SettingsStore.self) private var settingsStore: SettingsStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// A folder-choice problem to show under the destination it belongs to.
    @State private var folderErrors: [String: String] = [:]

    var body: some View {
        Section {
            ForEach(destinations) { destination in
                destinationGroup(destination)
            }
        } header: {
            SectionHeader(
                title: "Export",
                systemImage: SFSymbols.export,
                tint: .purple
            )
        }
    }

    // MARK: - Destination Group

    @ViewBuilder
    private func destinationGroup(_ destination: TranscriptExportDestination) -> some View {
        let config = settingsStore.exportConfig(for: destination)

        Toggle(
            "Export to \(destination.displayName)",
            isOn: enabledBinding(destination)
        )
        .accessibilityHint(AccessibilityHints.enable)

        if config.folderBookmark == nil {
            Text("Turning this on asks you to choose a folder.")
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
        }

        Text(
            "Saves each finished meeting as a Markdown file in a \(destination.displayName) folder. Transcripts in Wispr are unchanged."
        )
        .font(.caption)
        .foregroundStyle(theme.secondaryTextColor)

        HStack {
            Text("Folder")
                .foregroundStyle(theme.primaryTextColor)
            Spacer()
            Button(config.folderBookmark == nil ? "Choose…" : "Change…") {
                chooseFolder(for: destination)
            }
            .accessibilityHint(AccessibilityHints.chooseFolder)
            if config.folderBookmark != nil {
                Button("Clear") {
                    clearFolder(for: destination)
                }
                .accessibilityHint(AccessibilityHints.clearFolder)
            }
        }

        if let bookmark = config.folderBookmark {
            FolderPathText(bookmark: bookmark)
        }

        if config.folderUnavailable {
            Label("Folder unavailable. Choose it again.", systemImage: SFSymbols.warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        if let error = folderErrors[destination.id] {
            Label(error, systemImage: SFSymbols.warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        HStack {
            TextField("Subfolder (optional)", text: binding(destination, \.subfolder))
                .accessibilityHint(AccessibilityHints.subfolder)
            Button("Choose…") {
                chooseSubfolder(for: destination)
            }
            .disabled(config.folderBookmark == nil)
            .accessibilityHint(AccessibilityHints.chooseSubfolder)
        }

        if let message = Self.subfolderError(for: config.subfolder) {
            Label(message, systemImage: SFSymbols.warning)
                .font(.caption)
                .foregroundStyle(.orange)
        }

        Toggle("Include properties", isOn: binding(destination, \.includeFrontmatter))
            .accessibilityHint(AccessibilityHints.frontmatter)

        Text("Adds the title, date, duration, and speakers at the top of each file.")
            .font(.caption)
            .foregroundStyle(theme.secondaryTextColor)
    }

    // MARK: - Bindings and Actions

    /// A binding to one field of a destination's settings.
    private func binding<Value>(
        _ destination: TranscriptExportDestination,
        _ keyPath: WritableKeyPath<TranscriptExportConfig, Value>
    ) -> Binding<Value> {
        Binding(
            get: { settingsStore.exportConfig(for: destination)[keyPath: keyPath] },
            set: { newValue in
                settingsStore.updateExportConfig(for: destination) { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    /// The on/off switch. Turning it on without a folder asks for one first and
    /// stays off if the user cancels, so export is never on without a destination.
    private func enabledBinding(_ destination: TranscriptExportDestination) -> Binding<Bool> {
        Binding(
            get: { settingsStore.exportConfig(for: destination).enabled },
            set: { newValue in
                let hasFolder = settingsStore.exportConfig(for: destination).folderBookmark != nil
                if Self.needsFolderBeforeEnabling(turningOn: newValue, hasFolder: hasFolder) {
                    chooseFolder(for: destination, enableOnSuccess: true)
                } else {
                    settingsStore.updateExportConfig(for: destination) { $0.enabled = newValue }
                }
            }
        )
    }

    /// Asks the user for a folder and stores it as a security-scoped bookmark.
    ///
    /// The open panel is what grants sandbox access, so the bookmark has to be made
    /// from the URL it returns.
    private func chooseFolder(
        for destination: TranscriptExportDestination, enableOnSuccess: Bool = false
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the \(destination.displayName) folder that receives transcripts."

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        do {
            let bookmark = try TranscriptExporter.makeBookmark(for: chosen)
            settingsStore.updateExportConfig(for: destination) {
                $0.folderBookmark = bookmark
                $0.folderUnavailable = false
                if enableOnSuccess { $0.enabled = true }
            }
            folderErrors[destination.id] = nil
        } catch {
            folderErrors[destination.id] =
                "Could not save that folder choice: \(error.localizedDescription)"
        }
    }

    /// Lets the user pick the subfolder inside the export folder instead of typing it.
    ///
    /// The panel opens in the export folder. Only a folder directly inside it is
    /// accepted, because the subfolder setting is a single folder name.
    private func chooseSubfolder(for destination: TranscriptExportDestination) {
        let config = settingsStore.exportConfig(for: destination)
        guard let bookmark = config.folderBookmark else { return }

        var isStale = false
        guard
            let root = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale),
            root.startAccessingSecurityScopedResource()
        else {
            folderErrors[destination.id] = "Folder unavailable. Choose it again."
            return
        }
        defer { root.stopAccessingSecurityScopedResource() }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.prompt = "Choose"
        panel.message = "Choose a folder inside the export folder."

        guard panel.runModal() == .OK, let chosen = panel.url else { return }

        if let name = Self.subfolderName(chosen: chosen, root: root) {
            settingsStore.updateExportConfig(for: destination) { $0.subfolder = name }
            folderErrors[destination.id] = nil
        } else {
            folderErrors[destination.id] = "Choose a folder directly inside the export folder."
        }
    }

    /// Forgets the folder and switches the export off, so nothing is written
    /// anywhere the user did not pick.
    private func clearFolder(for destination: TranscriptExportDestination) {
        settingsStore.updateExportConfig(for: destination) {
            $0.folderBookmark = nil
            $0.folderUnavailable = false
            $0.enabled = false
        }
        folderErrors[destination.id] = nil
    }

    // MARK: - Helpers

    /// Whether flipping the switch must first ask for a folder.
    static func needsFolderBeforeEnabling(turningOn: Bool, hasFolder: Bool) -> Bool {
        turningOn && !hasFolder
    }

    /// The name of `chosen` when it sits directly inside `root`, otherwise `nil`.
    static func subfolderName(chosen: URL, root: URL) -> String? {
        let chosen = chosen.standardizedFileURL.resolvingSymlinksInPath()
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        guard chosen.deletingLastPathComponent().path == root.path else { return nil }
        let name = chosen.lastPathComponent
        return TranscriptExporter.isValid(subfolder: name) ? name : nil
    }

    /// The message to show under the subfolder field, or `nil` when the name is usable.
    static func subfolderError(for subfolder: String) -> String? {
        TranscriptExporter.isValid(subfolder: subfolder)
            ? nil
            : "Use a single folder name, without “/”, “:”, or a leading dot."
    }

    /// Home-abbreviated path of a bookmarked folder, for display only.
    ///
    /// Resolving without opening the security scope is enough to read the path.
    nonisolated static func displayPath(for bookmark: Data) -> String {
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale)
        else { return "Folder unavailable" }

        let path = url.path(percentEncoded: false)
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }
}

/// Shows the path a folder bookmark points to.
///
/// Resolving a bookmark is file-system work that can stall on a slow or missing
/// volume. It runs once per bookmark, off the main actor, instead of on every
/// redraw of the section, so typing in the subfolder field stays responsive.
private struct FolderPathText: View {
    let bookmark: Data

    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    @State private var path = ""

    var body: some View {
        Text(path)
            .font(.caption)
            .foregroundStyle(theme.secondaryTextColor)
            .textSelection(.enabled)
            .accessibilityLabel("Export folder: \(path)")
            .task(id: bookmark) {
                let data = bookmark
                path = await Task.detached { TranscriptExportSection.displayPath(for: data) }.value
            }
    }
}
