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
            isOn: binding(destination, \.enabled)
        )
        .disabled(config.folderBookmark == nil)
        .accessibilityHint(AccessibilityHints.enable)

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
            Text(Self.displayPath(for: bookmark))
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .textSelection(.enabled)
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

        TextField("Subfolder (optional)", text: binding(destination, \.subfolder))
            .accessibilityHint(AccessibilityHints.subfolder)

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

    /// Asks the user for a folder and stores it as a security-scoped bookmark.
    ///
    /// The open panel is what grants sandbox access, so the bookmark has to be made
    /// from the URL it returns.
    private func chooseFolder(for destination: TranscriptExportDestination) {
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
            }
            folderErrors[destination.id] = nil
        } catch {
            folderErrors[destination.id] =
                "Could not save that folder choice: \(error.localizedDescription)"
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

    /// The message to show under the subfolder field, or `nil` when the name is usable.
    static func subfolderError(for subfolder: String) -> String? {
        TranscriptExporter.isValid(subfolder: subfolder)
            ? nil
            : "Use a single folder name, without “/”, “:”, or a leading dot."
    }

    /// Home-abbreviated path of a bookmarked folder, for display only.
    ///
    /// Resolving without opening the security scope is enough to read the path.
    static func displayPath(for bookmark: Data) -> String {
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
