//
//  TranscriptStore.swift
//  wispr
//
//  Persists meeting transcripts to disk as JSON and reads them back so past
//  sessions can be browsed, renamed, and deleted.
//

import Foundation
import Synchronization
import WisprCore
import os

/// Lightweight metadata about a saved transcript, for list display.
///
/// Deliberately separate from `MeetingTranscript`: the history list only needs a
/// few fields, and carrying the full entry array for every file on disk would
/// make the list grow linearly with total transcribed minutes.
nonisolated struct TranscriptSummary: Identifiable, Sendable, Equatable {
    /// The transcript's file on disk. Doubles as a stable list identity.
    let url: URL
    /// When the meeting started, or the file's creation date if unreadable.
    let startTime: Date
    /// User-assigned session title, or `nil` when the session was never named.
    let title: String?
    /// Length of the meeting, derived from its entries.
    let duration: TimeInterval
    let entryCount: Int
    /// Resolved names of diarized speakers, in order of first appearance.
    let speakerNames: [String]
    /// First line of the transcript, for a preview in the list.
    let preview: String
    /// True when the file exists but could not be decoded. Such rows are shown
    /// rather than hidden, so a corrupt file is visible and deletable instead of
    /// silently vanishing.
    let isUnreadable: Bool

    var id: URL { url }

    var formattedDuration: String { MeetingTranscript.formatDuration(duration) }

    /// Whether the user gave this session a name of their own.
    var hasTitle: Bool { title?.isEmpty == false }
}

/// Persists meeting transcripts to disk.
///
/// Each session is written as a timestamped JSON file under
/// `ModelPaths.transcripts` (`<Application Support>/wispr/transcripts/`).
/// This guarantees that stopping a recording and immediately starting a new
/// one — which resets the in-memory transcript — never destroys prior data.
///
/// The whole type is `nonisolated` so that directory scans, decoding, and file
/// writes never run on the main actor by default. Under this package's
/// `.defaultIsolation(MainActor.self)` the default would be the opposite:
/// listing a hundred transcripts would decode them all on the UI thread.
///
/// This only makes the *type* callable off the main actor — it does not by
/// itself move a caller's work anywhere. Call through `TranscriptIO` (below)
/// to actually hop off the main actor via a structured `await` rather than
/// `Task.detached`. `finalizeForTermination()` is the one exception: it runs
/// synchronously from `applicationWillTerminate`, which cannot `await`, so it
/// calls these static members directly.
nonisolated enum TranscriptStore {

    /// Directory where transcript JSON files are stored.
    ///
    /// Resolved on every access rather than cached, so a folder change in Settings
    /// takes effect immediately for both reads and writes.
    static var directory: URL { TranscriptLocation.current }

    /// Prefix and extension identifying transcript files in the directory.
    private static let filePrefix = "meeting-"
    private static let fileExtension = "json"

    /// Upper bound on the title fragment appended to a filename. Long enough to
    /// stay recognisable in Finder, short enough to leave room for the timestamp
    /// and a collision suffix within the filesystem's per-component limit.
    private static let slugMaxLength = 60

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    /// Mirrors `encoder`'s date strategy — a mismatch here silently breaks
    /// decoding of every file the app has ever written.
    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// File-name timestamp formatter (e.g. `2026-06-22_14-30-05`).
    private static let filenameFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter
    }()

    // MARK: - Writing

    /// Persists a transcript to disk as a new JSON file.
    ///
    /// Empty transcripts (no entries) are ignored so we don't litter the
    /// directory with blank sessions.
    ///
    /// - Parameter transcript: The completed session to save.
    /// - Returns: The URL of the written file, or `nil` if nothing was saved.
    @discardableResult
    static func save(_ transcript: MeetingTranscript) -> URL? {
        guard !transcript.entries.isEmpty else {
            Log.stateManager.debug("TranscriptStore — skipping save of empty transcript")
            return nil
        }

        do {
            let url = try fileURL(for: transcript.startTime, title: transcript.title)
            try write(transcript, to: url)
            Log.stateManager.debug(
                "TranscriptStore — saved transcript (\(transcript.entries.count) entries) to \(url.lastPathComponent)"
            )
            return url
        } catch {
            Log.stateManager.error(
                "TranscriptStore — failed to save transcript: \(error.localizedDescription)")
            return nil
        }
    }

    /// Overwrites an existing transcript file in place.
    ///
    /// Used when editing an archived transcript (e.g. renaming a speaker), where
    /// `save` would create a second file instead of updating the original.
    static func save(_ transcript: MeetingTranscript, to url: URL) throws {
        try write(transcript, to: url)
        Log.stateManager.debug(
            "TranscriptStore — updated transcript at \(url.lastPathComponent)")
    }

    // MARK: - Reading

    /// Summaries already computed, keyed by file URL and tagged with the file's
    /// modification date at the time they were built.
    ///
    /// `list()` runs on every window appear, after each rename/retitle/delete, on
    /// debounced external filesystem changes, and on meeting stop, so its cost
    /// scales with total transcribed minutes across every saved session and
    /// repeats often. A summary only needs a preview line, entry count, duration,
    /// and speaker names, but building one from scratch decodes the whole
    /// transcript — every entry — which is exactly the cost `TranscriptSummary`
    /// exists to avoid paying just to list. Keying by mtime rather than trusting
    /// the cache unconditionally means an edit made outside this cache — Finder,
    /// another process, a future code path that writes the file directly — is
    /// picked up on the next scan instead of serving a stale summary forever.
    private static let summaryCache = Mutex<[URL: (modified: Date, summary: TranscriptSummary)]>(
        [:])

    /// All saved transcripts, most recent first.
    ///
    /// A file that cannot be decoded yields a summary with `isUnreadable = true`
    /// rather than being skipped or aborting the scan, so corruption is visible
    /// to the user instead of looking like data loss.
    static func list() -> [TranscriptSummary] {
        let fileManager = FileManager.default
        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            // A missing directory just means nothing has been recorded yet.
            return []
        }

        let candidates = urls.filter {
            $0.pathExtension == fileExtension && $0.lastPathComponent.hasPrefix(filePrefix)
        }

        return candidates
            .map(cachedSummary(for:))
            .sorted { $0.startTime > $1.startTime }
    }

    /// Returns a cached summary for `url` when its modification date matches what
    /// was cached, otherwise decodes the file and caches the result.
    private static func cachedSummary(for url: URL) -> TranscriptSummary {
        let modified = fileModificationDate(url) ?? .distantPast

        if let cached = summaryCache.withLock({ $0[url] }), cached.modified == modified {
            return cached.summary
        }

        let built = summary(for: url)
        summaryCache.withLock { $0[url] = (modified, built) }
        return built
    }

    /// Loads a full transcript from disk.
    static func load(_ url: URL) throws -> MeetingTranscript {
        let data = try Data(contentsOf: url)
        return try decoder.decode(MeetingTranscript.self, from: data)
    }

    /// Permanently deletes a transcript file.
    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        summaryCache.withLock { $0[url] = nil }
        Log.stateManager.debug("TranscriptStore — deleted \(url.lastPathComponent)")
    }

    // MARK: - Renaming

    /// Renames a transcript file so its name reflects the session title.
    ///
    /// The `meeting-<timestamp>` head is preserved and the sanitised title
    /// appended: `list()` keys off that prefix, so a free-form filename would make
    /// the transcript invisible in the history sidebar. Clearing the title returns
    /// the file to its timestamp-only name.
    ///
    /// - Returns: The resulting URL, which equals `url` when no rename was needed.
    static func rename(at url: URL, startTime: Date, title: String?) throws -> URL {
        let target = try fileURL(for: startTime, title: title, ignoring: url)
        guard target != url else { return url }

        try FileManager.default.moveItem(at: url, to: target)
        // The cache is keyed by URL, so the entry under the old URL has to move
        // with the file or the next `list()` would treat the new URL as an
        // uncached miss and decode a file whose content — and so summary — did
        // not actually change; `moveItem` preserves the modification date, so the
        // carried entry's staleness check still holds under the new URL. Dropping
        // the old URL's entry either way also prevents it being served if that
        // path is ever reused (a rename back to a previous title).
        summaryCache.withLock { cache in
            let carried = cache.removeValue(forKey: url)
            if let carried {
                cache[target] = (carried.modified, retargeted(carried.summary, to: target))
            }
        }
        Log.stateManager.debug(
            "TranscriptStore — renamed \(url.lastPathComponent) to \(target.lastPathComponent)")
        return target
    }

    /// Copies a summary onto a new URL, for carrying a cache entry across a
    /// rename where the file's content — and so every other field — is unchanged.
    private static func retargeted(_ summary: TranscriptSummary, to url: URL) -> TranscriptSummary {
        TranscriptSummary(
            url: url,
            startTime: summary.startTime,
            title: summary.title,
            duration: summary.duration,
            entryCount: summary.entryCount,
            speakerNames: summary.speakerNames,
            preview: summary.preview,
            isUnreadable: summary.isUnreadable
        )
    }

    /// Converts a session title into a filename-safe fragment.
    ///
    /// Letters and digits are kept (accents included — APFS handles them fine);
    /// every other run of characters collapses to a single dash. Separators are
    /// only emitted *before* a subsequent alphanumeric, so the result can never
    /// carry a leading or trailing dash, and truncation always lands on a
    /// character rather than mid-separator.
    ///
    /// Returns an empty string when nothing usable survives — a title made only of
    /// punctuation or emoji — in which case callers fall back to the
    /// timestamp-only name.
    static func slug(from title: String?) -> String {
        guard let title else { return "" }

        var slug = ""
        var pendingSeparator = false

        for character in title {
            guard character.isLetter || character.isNumber else {
                pendingSeparator = true
                continue
            }

            // Account for the separator before appending anything, otherwise a
            // separator plus a character can carry the slug one past the cap.
            let needsSeparator = pendingSeparator && !slug.isEmpty
            guard slug.count + (needsSeparator ? 2 : 1) <= slugMaxLength else { break }

            if needsSeparator { slug.append("-") }
            pendingSeparator = false
            slug.append(character)
        }

        return slug
    }

    // MARK: - Private

    private static func write(_ transcript: MeetingTranscript, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: .atomic)

        // Populate the cache from the transcript already in hand, rather than
        // leaving the next `list()` to decode the file this call just wrote.
        // Not required for correctness — `cachedSummary(for:)`'s own mtime check
        // already invalidates correctly on a fresh `URL` from
        // `contentsOfDirectory`, which is what `list()` uses — but it avoids
        // decoding a transcript that is, at this point, already sitting in memory.
        let built = summary(from: transcript, url: url)
        let modified = fileModificationDate(url) ?? .distantPast
        summaryCache.withLock { $0[url] = (modified, built) }
    }

    /// Builds a unique file URL for a session start time and optional title.
    ///
    /// Two meetings can start within the same second (a mistaken stop followed
    /// by an immediate restart), which the timestamp alone cannot distinguish —
    /// the second would silently overwrite the first. A numeric suffix is added
    /// when needed.
    ///
    /// - Parameter ignoring: A file to treat as available. Renaming passes the file
    ///   being renamed, so re-applying the same title is a no-op instead of
    ///   colliding with itself and bumping to `-2`.
    private static func fileURL(
        for startTime: Date,
        title: String? = nil,
        ignoring existing: URL? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let dir = directory
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = filenameFormatter.string(from: startTime)
        let titleSlug = slug(from: title)
        let stem = titleSlug.isEmpty
            ? "\(filePrefix)\(stamp)"
            : "\(filePrefix)\(stamp)-\(titleSlug)"

        func candidate(suffix: Int?) -> URL {
            let name = suffix.map { "\(stem)-\($0).\(fileExtension)" } ?? "\(stem).\(fileExtension)"
            return dir.appendingPathComponent(name, isDirectory: false)
        }

        func isAvailable(_ url: URL) -> Bool {
            url == existing || !fileManager.fileExists(atPath: url.path)
        }

        let base = candidate(suffix: nil)
        if isAvailable(base) { return base }

        for suffix in 2...99 {
            let candidate = candidate(suffix: suffix)
            if isAvailable(candidate) { return candidate }
        }

        // Astronomically unlikely; fall back to overwriting rather than failing
        // to persist a real meeting.
        return base
    }

    /// Reads just enough of a file to describe it in the history list.
    private static func summary(for url: URL) -> TranscriptSummary {
        guard let transcript = try? load(url) else {
            Log.stateManager.warning(
                "TranscriptStore — unreadable transcript: \(url.lastPathComponent)")
            return TranscriptSummary(
                url: url,
                startTime: fileCreationDate(url) ?? .distantPast,
                title: nil,
                duration: 0,
                entryCount: 0,
                speakerNames: [],
                preview: "",
                isUnreadable: true
            )
        }
        return summary(from: transcript, url: url)
    }

    /// Builds a summary from a transcript already decoded in memory.
    ///
    /// Split out from `summary(for:)` so `write(_:to:)` can refresh the cache
    /// from the transcript it just encoded, instead of re-reading and
    /// re-decoding the file it only just wrote.
    private static func summary(from transcript: MeetingTranscript, url: URL) -> TranscriptSummary {
        let names = transcript.presentSpeakerIndices.map { index in
            transcript.displayName(for: .others(speakerIndex: index))
        }

        return TranscriptSummary(
            url: url,
            startTime: transcript.startTime,
            title: transcript.title,
            duration: transcript.contentDuration,
            entryCount: transcript.entries.count,
            speakerNames: names,
            preview: transcript.entries.first?.text ?? "",
            isUnreadable: false
        )
    }

    private static func fileCreationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
    }

    /// Drives the summary cache's staleness check: a file rewritten by `save`
    /// (including through this process) or edited outside it gets a new
    /// modification date, which is what tells `cachedSummary(for:)` to re-decode.
    private static func fileModificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// Runs `TranscriptStore`'s file I/O off the main actor through a real
/// structured-concurrency boundary.
///
/// `TranscriptStore` itself is a `nonisolated enum` of `static` members, so
/// there is no instance for actor isolation to attach to — it cannot become
/// an `actor` in the usual sense. This actor exists to give callers something
/// to `await` into instead: unlike `Task.detached`, an `await` on an actor
/// method inherits the caller's priority, task-local values, and cancellation
/// (see CLAUDE.md's "Structured concurrency only" rule under Concurrency
/// Patterns).
///
/// `TranscriptStore`'s own file operations stay synchronous: they are the
/// right shape for `finalizeForTermination()`, which runs from
/// `applicationWillTerminate` and cannot `await` at all.
actor TranscriptIO {
    static let shared = TranscriptIO()

    private init() {}

    func list() -> [TranscriptSummary] {
        TranscriptStore.list()
    }

    func load(_ url: URL) throws -> MeetingTranscript {
        try TranscriptStore.load(url)
    }

    @discardableResult
    func save(_ transcript: MeetingTranscript) -> URL? {
        TranscriptStore.save(transcript)
    }

    func save(_ transcript: MeetingTranscript, to url: URL) throws {
        try TranscriptStore.save(transcript, to: url)
    }

    func delete(_ url: URL) throws {
        try TranscriptStore.delete(url)
    }

    func rename(at url: URL, startTime: Date, title: String?) throws -> URL {
        try TranscriptStore.rename(at: url, startTime: startTime, title: title)
    }
}
