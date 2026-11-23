//
//  TranscriptExporter.swift
//  wispr
//
//  Writes a Markdown copy of a saved meeting transcript into the folder the user
//  chose for an export destination.
//

import Foundation
import WisprCore

/// File-level work for exporting a meeting transcript as Markdown.
///
/// `nonisolated` so the same static members serve the async stop path and the
/// synchronous app-termination path, like `TranscriptStore`.
nonisolated enum TranscriptExporter {

    /// Why an export could not be written.
    enum ExportError: Error, LocalizedError, Equatable {
        /// The subfolder name is empty of meaning or tries to leave the chosen folder.
        case invalidSubfolder
        /// The saved folder can no longer be opened (moved, deleted, unmounted, or
        /// access was revoked). The user needs to choose it again.
        case folderUnavailable(String)
        /// Every candidate file name in the folder is already taken.
        case noFreeFileName

        var errorDescription: String? {
            switch self {
            case .invalidSubfolder:
                return "The subfolder name is not valid."
            case .folderUnavailable(let reason):
                return "The export folder is unavailable. \(reason)"
            case .noFreeFileName:
                return "A file with every candidate name already exists in the export folder."
            }
        }
    }

    /// What a successful export produced.
    struct Result: Sendable, Equatable {
        /// The file that was written.
        let url: URL
        /// A replacement for the stored bookmark, set when the stored one had gone
        /// stale and the caller should persist the new one.
        let refreshedBookmark: Data?
    }

    /// Highest numeric suffix tried when a file name is already taken.
    private static let maxCollisionSuffix = 99

    // MARK: - Naming

    private static let nameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HH-mm"
        return formatter
    }()

    /// The file name without extension: the meeting's start time, followed by the
    /// title when there is one (for example `2026-11-22-13-30-Sprint-review`).
    static func fileStem(startTime: Date, title: String?) -> String {
        let stamp = nameFormatter.string(from: startTime)
        let slug = TranscriptStore.slug(from: title)
        return slug.isEmpty ? stamp : "\(stamp)-\(slug)"
    }

    /// Whether `subfolder` can be created inside the chosen folder.
    ///
    /// Empty is valid and means "no subfolder". A name is rejected when it contains
    /// a path separator, is `.` or `..`, or starts with a dot, which would hide the
    /// folder or point into an app's own configuration folder such as `.obsidian`.
    static func isValid(subfolder: String) -> Bool {
        let name = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return true }
        if name.contains("/") || name.contains("\\") || name.contains(":") { return false }
        if name.hasPrefix(".") { return false }
        return true
    }

    // MARK: - Writing

    /// Writes `markdown` into `folder` (inside `subfolder` when given) under a name
    /// built from `stem`, adding `-2`, `-3`, … when the name is taken.
    ///
    /// An existing file is never replaced: the write itself refuses to overwrite,
    /// so two exports racing for the same name cannot clobber each other.
    static func write(
        markdown: String,
        stem: String,
        in folder: URL,
        subfolder: String
    ) throws -> URL {
        guard isValid(subfolder: subfolder) else { throw ExportError.invalidSubfolder }

        let name = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = name.isEmpty ? folder : folder.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let data = Data(markdown.utf8)
        for suffix in [nil] + Array(2...maxCollisionSuffix) {
            let fileName = suffix.map { "\(stem)-\($0).md" } ?? "\(stem).md"
            let url = directory.appendingPathComponent(fileName, isDirectory: false)
            do {
                try data.write(to: url, options: [.withoutOverwriting])
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ExportError.noFreeFileName
    }

    // MARK: - Folder access

    /// Builds the bookmark to store for a folder the user just picked in an open panel.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Opens the security scope for the bookmarked folder, runs `body`, and always
    /// closes the scope again.
    ///
    /// The scope is held only for the duration of one export. A folder that is
    /// never held open cannot leak an access count when the user changes it.
    ///
    /// - Returns: `body`'s value and, when the stored bookmark was stale, a fresh one.
    static func withFolder<T>(
        bookmark: Data,
        _ body: (URL) throws -> T
    ) throws -> (value: T, refreshedBookmark: Data?) {
        var isStale = false
        let folder: URL
        do {
            folder = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            throw ExportError.folderUnavailable(error.localizedDescription)
        }

        guard folder.startAccessingSecurityScopedResource() else {
            throw ExportError.folderUnavailable(
                "macOS denied access to “\(folder.lastPathComponent)”.")
        }
        defer { folder.stopAccessingSecurityScopedResource() }

        let value = try body(folder)
        let refreshed = isStale ? try? makeBookmark(for: folder) : nil
        return (value, refreshed)
    }

    // MARK: - Export

    /// Renders `transcript` and writes it to the folder in `config`.
    static func export(
        _ transcript: MeetingTranscript,
        using config: TranscriptExportConfig
    ) throws -> Result {
        guard let bookmark = config.folderBookmark else {
            throw ExportError.folderUnavailable("No folder has been chosen.")
        }
        guard isValid(subfolder: config.subfolder) else { throw ExportError.invalidSubfolder }

        let markdown = TranscriptMarkdownRenderer.render(
            transcript, includeFrontmatter: config.includeFrontmatter)
        let stem = fileStem(startTime: transcript.startTime, title: transcript.title)

        let (url, refreshed) = try withFolder(bookmark: bookmark) { folder in
            try write(markdown: markdown, stem: stem, in: folder, subfolder: config.subfolder)
        }
        return Result(url: url, refreshedBookmark: refreshed)
    }
}
