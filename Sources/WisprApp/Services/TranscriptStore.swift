//
//  TranscriptStore.swift
//  wispr
//
//  Persists completed meeting transcripts to disk as JSON so a session is
//  never lost when a new recording is started.
//

import Foundation
import WisprCore
import os

/// Persists meeting transcripts to disk.
///
/// Each completed session is written as a timestamped JSON file under
/// `ModelPaths.transcripts` (`<Application Support>/wispr/transcripts/`).
/// This guarantees that stopping a recording and immediately starting a new
/// one — which resets the in-memory transcript — never destroys prior data.
enum TranscriptStore {

    /// Directory where transcript JSON files are stored.
    static var directory: URL { ModelPaths.transcripts }

    /// Every saved session's filename starts with this, so `list()` can tell
    /// them apart from anything else that ends up in the directory.
    static let filePrefix = "meeting-"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

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

    /// Persists a transcript to disk as a JSON file.
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

        let fileManager = FileManager.default
        let dir = directory

        do {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

            let filename = "meeting-\(filenameFormatter.string(from: transcript.startTime)).json"
            let url = dir.appendingPathComponent(filename, isDirectory: false)

            let data = try encoder.encode(transcript)
            try data.write(to: url, options: .atomic)

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
    /// - Returns: `true` if the file was written.
    @discardableResult
    static func save(_ transcript: MeetingTranscript, to url: URL) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            let data = try encoder.encode(transcript)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Log.stateManager.error(
                "TranscriptStore — failed to write \(url.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }
    }

    // MARK: - Reading

    /// Every saved session, newest first.
    ///
    /// A file that cannot be decoded is skipped and logged rather than aborting
    /// the listing, so one damaged file does not hide the rest of the history.
    static func list() -> [TranscriptSummary] {
        let fileManager = FileManager.default

        guard
            let urls = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            // No directory yet simply means nothing has been recorded.
            return []
        }

        let candidates = urls.filter {
            $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix(filePrefix)
        }

        var summaries: [TranscriptSummary] = []
        for url in candidates {
            guard let transcript = load(url) else { continue }
            summaries.append(
                TranscriptSummary(
                    url: url,
                    startTime: transcript.startTime,
                    title: transcript.title,
                    entryCount: transcript.entries.count,
                    span: transcript.recordedSpan,
                    preview: transcript.entries.first?.text
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                )
            )
        }

        return summaries.sorted { $0.startTime > $1.startTime }
    }

    /// Decodes a single saved session.
    static func load(_ url: URL) -> MeetingTranscript? {
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(MeetingTranscript.self, from: data)
        } catch {
            Log.stateManager.warning(
                "TranscriptStore — could not read \(url.lastPathComponent): \(error.localizedDescription)"
            )
            return nil
        }
    }

    // MARK: - Mutating

    /// Deletes a saved session.
    ///
    /// wispr keeps no audio, so a deleted transcript cannot be recreated: callers
    /// are expected to have confirmed with the user first.
    @discardableResult
    static func delete(_ url: URL) -> Bool {
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            Log.stateManager.error(
                "TranscriptStore — failed to delete \(url.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }
    }

    /// Names a session, or clears the name when passed `nil` or whitespace.
    ///
    /// The title is stored inside the JSON; the filename keeps its `meeting-` +
    /// timestamp form and gains a slug of the title, so `list()` still finds the
    /// file and the timestamp stays authoritative. Nothing is ever read back out
    /// of the filename, so the two cannot drift into disagreement.
    ///
    /// - Returns: The file's URL, which changes when the slug changes.
    @discardableResult
    static func rename(_ url: URL, to title: String?) -> URL? {
        guard var transcript = load(url) else { return nil }

        let cleaned = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        transcript.title = (cleaned?.isEmpty ?? true) ? nil : cleaned

        // Write the title first: if the move then fails, the rename is still
        // recorded rather than lost.
        guard save(transcript, to: url) else { return nil }

        let target = uniqueURL(for: transcript, excluding: url)
        guard target != url else { return url }

        do {
            try FileManager.default.moveItem(at: url, to: target)
            return target
        } catch {
            Log.stateManager.error(
                "TranscriptStore — renamed in place but could not move file: \(error.localizedDescription)"
            )
            // The title did land, so report the original URL rather than failing.
            return url
        }
    }

    // MARK: - Naming

    /// `meeting-<timestamp>.json`, with a slug of the title appended when there
    /// is one, and a numeric suffix if that name is already taken.
    private static func uniqueURL(
        for transcript: MeetingTranscript,
        excluding current: URL? = nil
    ) -> URL {
        var base = filePrefix + filenameFormatter.string(from: transcript.startTime)
        if let slug = slug(from: transcript.title) {
            base += "-" + slug
        }

        var candidate = directory.appendingPathComponent(base + ".json", isDirectory: false)
        var counter = 2

        while FileManager.default.fileExists(atPath: candidate.path), candidate != current {
            candidate = directory.appendingPathComponent(
                "\(base)-\(counter).json", isDirectory: false)
            counter += 1
        }

        return candidate
    }

    /// Lowercased, hyphen-separated and length-capped, so the filename stays
    /// sane regardless of what the user typed.
    private static func slug(from title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }

        let mapped = title.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")

        guard !collapsed.isEmpty else { return nil }
        return String(collapsed.prefix(40))
    }
}

/// A lightweight description of a saved session, so the history list can be
/// rendered without holding every full transcript in memory.
struct TranscriptSummary: Identifiable, Sendable, Equatable {
    let url: URL
    let startTime: Date
    let title: String?
    let entryCount: Int
    let span: TimeInterval
    /// Opening words of the session, for a one-line hint under the title.
    let preview: String

    var id: URL { url }

    /// The user's name for the session, or its date when unnamed.
    var displayName: String {
        if let title, !title.isEmpty { return title }
        return Self.dateFormatter.string(from: startTime)
    }

    /// `span` as "h:mm:ss", hours omitted when zero.
    var formattedSpan: String {
        let total = Int(span)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
