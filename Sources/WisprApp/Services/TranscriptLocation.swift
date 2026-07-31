//
//  TranscriptLocation.swift
//  wispr
//
//  Resolves the folder meeting transcripts are read from and written to,
//  honouring a user-chosen folder when one has been picked in Settings.
//

import Foundation
import Synchronization
import WisprCore
import os

/// Where meeting transcripts live on disk.
///
/// Defaults to the app's own container (`ModelPaths.transcripts`). The user can
/// point this at any folder from Settings, which brings two sandbox obligations
/// that are owned here so callers can keep treating the location as a plain
/// `URL`:
///
/// - the choice only survives a relaunch as a **security-scoped bookmark**;
///   a stored path string resolves to a folder the app may no longer open;
/// - the scope has to be explicitly opened before any read or write, and closed
///   when we move off it.
///
/// Implemented as a `nonisolated` type over a `Mutex` rather than an actor
/// because `TranscriptStore` reads the directory synchronously from detached
/// tasks. Making the location `async` would force every call site to await —
/// including `save`, which runs on the recording path.
nonisolated enum TranscriptLocation {

    /// A resolved custom folder whose security scope is currently held open.
    private struct Scope: Sendable {
        let url: URL
        /// Whether the sandbox scope was opened, and therefore has to be balanced
        /// by `stopAccessingSecurityScopedResource()` when we move off it.
        let holdsSecurityScope: Bool
    }

    /// `nil` means "no custom folder" — transcripts go to the app container.
    private static let scope = Mutex<Scope?>(nil)

    /// Live listeners for folder changes, keyed so each can remove itself.
    private static let observers = Mutex<[UUID: AsyncStream<URL>.Continuation]>([:])

    // MARK: - Change notification

    /// Emits the new folder each time the location changes.
    ///
    /// Anything listing transcripts has to rescan on a change: summaries are keyed
    /// by file URL, so a stale list points every action — opening, revealing in
    /// Finder, deleting — at the previous folder.
    static func changes() -> AsyncStream<URL> {
        AsyncStream { continuation in
            let id = UUID()
            observers.withLock { $0[id] = continuation }
            continuation.onTermination = { _ in
                observers.withLock { $0[id] = nil }
            }
        }
    }

    private static func broadcast(_ directory: URL) {
        let continuations = observers.withLock { Array($0.values) }
        for continuation in continuations {
            continuation.yield(directory)
        }
    }

    // MARK: - Resolution

    /// The folder transcripts are stored in right now.
    static var current: URL {
        scope.withLock { $0?.url } ?? defaultDirectory
    }

    /// The in-container folder used when the user has not chosen one.
    static var defaultDirectory: URL { ModelPaths.transcripts }

    /// Whether a user-chosen folder is in force.
    static var isCustom: Bool {
        scope.withLock { $0 != nil }
    }

    // MARK: - Bookmarks

    /// Builds the bookmark to persist for a folder the user just picked.
    ///
    /// Only meaningful for a URL that came from an `NSOpenPanel`: the sandbox
    /// grants access to that specific selection, and the bookmark is what carries
    /// the grant across launches.
    static func makeBookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }

    /// Outcome of pointing the store at a stored bookmark.
    enum Activation: Sendable {
        /// The folder is now in use. `refreshedBookmark` is non-nil when the
        /// stored bookmark had gone stale and the caller should replace it.
        case activated(URL, refreshedBookmark: Data?)
        /// The bookmark could not be used; the default folder stays in force.
        case failed(String)
    }

    /// Resolves a bookmark and, if it works, makes that folder the current one.
    ///
    /// On any failure the default folder is restored rather than left pointing at
    /// an unusable location — transcripts written somewhere the user cannot reach
    /// are worse than transcripts written to the default folder.
    static func activate(bookmark data: Data) -> Activation {
        var isStale = false
        let resolved: URL
        do {
            resolved = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        } catch {
            useDefault()
            return .failed(error.localizedDescription)
        }

        guard resolved.startAccessingSecurityScopedResource() else {
            useDefault()
            return .failed("macOS denied access to “\(resolved.lastPathComponent)”.")
        }

        // Creating the folder now, rather than lazily on the first save, surfaces
        // an unwritable location while we can still fall back to the default.
        do {
            try FileManager.default.createDirectory(
                at: resolved, withIntermediateDirectories: true)
        } catch {
            resolved.stopAccessingSecurityScopedResource()
            useDefault()
            return .failed(error.localizedDescription)
        }

        replaceScope(with: Scope(url: resolved, holdsSecurityScope: true))

        // A stale bookmark still resolves, but only until the folder moves again;
        // hand a fresh one back so the caller can persist it.
        let refreshed = isStale ? try? makeBookmark(for: resolved) : nil
        return .activated(resolved, refreshedBookmark: refreshed)
    }

    /// Drops any custom folder and returns to the app container.
    static func useDefault() {
        replaceScope(with: nil)
    }

    // MARK: - Settings integration

    /// Points the store at the folder saved in settings, if any.
    ///
    /// Call at launch and after the user picks a folder. Returns a message to
    /// surface when a saved folder could not be used — in that case the stored
    /// bookmark is cleared so the app stops retrying a folder that has been
    /// deleted or unmounted.
    @MainActor
    @discardableResult
    static func applyStoredFolder(from settings: SettingsStore) -> String? {
        guard let data = settings.transcriptsFolderBookmark else {
            useDefault()
            return nil
        }

        switch activate(bookmark: data) {
        case .activated(let url, let refreshedBookmark):
            if let refreshedBookmark {
                settings.transcriptsFolderBookmark = refreshedBookmark
            }
            Log.stateManager.debug(
                "TranscriptLocation — using custom folder \(url.lastPathComponent)")
            return nil

        case .failed(let reason):
            settings.transcriptsFolderBookmark = nil
            Log.stateManager.error("TranscriptLocation — saved folder unusable: \(reason)")
            return
                "Wispr could not use the saved transcripts folder and went back to the default location. (\(reason))"
        }
    }

    // MARK: - Private

    private static func replaceScope(with new: Scope?) {
        let previous = scope.withLock { stored -> Scope? in
            let old = stored
            stored = new
            return old
        }

        // Compare effective folders, not the stored scopes: dropping a custom
        // folder moves transcripts back to the container, which is a change even
        // though the new scope is nil.
        let previousDirectory = previous?.url ?? defaultDirectory
        let newDirectory = new?.url ?? defaultDirectory

        // Skip when the same folder is being re-activated: the access counter was
        // just incremented for it, and closing here would undo that.
        if let previous, previous.holdsSecurityScope, previous.url != new?.url {
            previous.url.stopAccessingSecurityScopedResource()
        }

        guard previousDirectory != newDirectory else { return }
        broadcast(newDirectory)
    }
}
