//
//  TranscriptStore.swift
//  wispr
//
//  Persists meeting transcripts to disk as JSON and reads them back so past
//  sessions can be browsed, renamed, and deleted.
//

import Foundation
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
/// writes never run on the main actor. Under this package's
/// `.defaultIsolation(MainActor.self)` the default would be the opposite:
/// listing a hundred transcripts would decode them all on the UI thread.
nonisolated enum TranscriptStore {

    /// Directory where transcript JSON files are stored.
    static var directory: URL { ModelPaths.transcripts }

    /// Prefix and extension identifying transcript files in the directory.
    private static let filePrefix = "meeting-"
    private static let fileExtension = "json"

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
            let url = try fileURL(for: transcript.startTime)
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
                includingPropertiesForKeys: [.creationDateKey],
                options: [.skipsHiddenFiles]
            )
        else {
            // A missing directory just means nothing has been recorded yet.
            return []
        }

        return urls
            .filter {
                $0.pathExtension == fileExtension
                    && $0.lastPathComponent.hasPrefix(filePrefix)
            }
            .map(summary(for:))
            .sorted { $0.startTime > $1.startTime }
    }

    /// Loads a full transcript from disk.
    static func load(_ url: URL) throws -> MeetingTranscript {
        let data = try Data(contentsOf: url)
        return try decoder.decode(MeetingTranscript.self, from: data)
    }

    /// Permanently deletes a transcript file.
    static func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        Log.stateManager.debug("TranscriptStore — deleted \(url.lastPathComponent)")
    }

    // MARK: - Private

    private static func write(_ transcript: MeetingTranscript, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try encoder.encode(transcript)
        try data.write(to: url, options: .atomic)
    }

    /// Builds a unique file URL for a session start time.
    ///
    /// Two meetings can start within the same second (a mistaken stop followed
    /// by an immediate restart), which the timestamp alone cannot distinguish —
    /// the second would silently overwrite the first. A numeric suffix is added
    /// when needed.
    private static func fileURL(for startTime: Date) throws -> URL {
        let fileManager = FileManager.default
        let dir = directory
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let stamp = filenameFormatter.string(from: startTime)
        let base = dir.appendingPathComponent(
            "\(filePrefix)\(stamp).\(fileExtension)", isDirectory: false)
        guard fileManager.fileExists(atPath: base.path) else { return base }

        for suffix in 2...99 {
            let candidate = dir.appendingPathComponent(
                "\(filePrefix)\(stamp)-\(suffix).\(fileExtension)", isDirectory: false)
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
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
}
