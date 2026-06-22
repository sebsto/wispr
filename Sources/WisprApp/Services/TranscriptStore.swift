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

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
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
}
