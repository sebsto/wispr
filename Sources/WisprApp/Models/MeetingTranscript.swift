//
//  MeetingTranscript.swift
//  wispr
//
//  Data model for meeting transcription entries with speaker labels.
//

import Foundation

/// Identifies the audio source / speaker in a meeting transcript.///
/// Speaker indices are stored **0-based** internally. The +1 transform to
/// "Speaker 1", "Speaker 2", etc. happens only inside `displayName`.
enum MeetingSpeaker: Sendable, Equatable, Hashable, Codable {
    case you
    /// Remote participant. `speakerIndex` is nil during Sortformer's cold-start
    /// window or when diarization is disabled — renders as plain "Others".
    case others(speakerIndex: Int?)

    /// User-visible label for transcript display and plain-text export.
    var displayName: String {
        switch self {
        case .you: return "You"
        case .others(.none): return "Others"
        case .others(.some(let index)): return "Speaker \(index + 1)"
        }
    }

    /// Whether this speaker is a remote participant (system-audio track),
    /// regardless of the resolved diarization index.
    var isRemote: Bool {
        if case .others = self { return true }
        return false
    }
}

/// A single timestamped entry in a meeting transcript.
struct MeetingTranscriptEntry: Identifiable, Sendable, Equatable, Codable {
    let id: UUID
    let speaker: MeetingSpeaker
    let text: String
    let timestamp: Date

    init(speaker: MeetingSpeaker, text: String, timestamp: Date = Date()) {
        self.id = UUID()
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
    }
}

/// The full transcript of a meeting session.
struct MeetingTranscript: Sendable, Equatable, Codable {
    var entries: [MeetingTranscriptEntry] = []
    let startTime: Date

    init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    // MARK: - Echo Suppression

    /// How far back (in seconds) to look for a matching entry on the other
    /// audio track when detecting microphone echo. Mic and system chunks are
    /// transcribed independently and on different chunk boundaries, so the two
    /// copies of the same utterance can land a few seconds apart.
    static let echoSuppressionWindow: TimeInterval = 8

    /// Minimum normalized similarity (0...1) between two entries' text for them
    /// to be considered the same utterance. ASR of speaker-echo is usually a
    /// near-perfect copy, so a high threshold keeps false positives rare.
    static let echoSimilarityThreshold = 0.8

    /// Utterances shorter than this (in words) are not echo-suppressed. Short
    /// backchannels ("yes", "right", "okay") are commonly said by both sides,
    /// so suppressing them would risk dropping genuine speech.
    static let minimumEchoWordCount = 3

    /// Appends `entry`, suppressing microphone echo of remote (system) audio.
    ///
    /// In meeting mode without headphones, remote participants' speech plays out
    /// of the speakers and leaks back into the microphone, producing a duplicate
    /// "You" entry that mirrors an "Others" entry (see issue #65). When a "You"
    /// entry closely matches a recent "Others" entry — or a newly arriving
    /// "Others" entry matches a recent "You" entry — the microphone copy is
    /// treated as echo: the utterance is attributed to the remote participant
    /// and the "You" copy is dropped.
    ///
    /// Handles both arrival orders (mic-first or system-first) since the two
    /// transcription paths run concurrently.
    ///
    /// - Returns: `true` if `entry` was added to the transcript, `false` if it
    ///   was suppressed as microphone echo.
    @discardableResult
    mutating func appendSuppressingEcho(_ entry: MeetingTranscriptEntry) -> Bool {
        let normalized = Self.normalizedForComparison(entry.text)
        guard normalized.split(separator: " ").count >= Self.minimumEchoWordCount else {
            entries.append(entry)
            return true
        }

        switch entry.speaker {
        case .you:
            // A mic entry echoing a recent remote utterance is dropped.
            if recentEchoMatchIndex(of: normalized, isRemote: true, before: entry.timestamp) != nil
            {
                return false
            }
            entries.append(entry)
            return true

        case .others:
            // A remote utterance that a recent mic entry already echoed: drop the
            // earlier mic echo and keep this (authoritative) remote entry.
            if let echoIndex = recentEchoMatchIndex(
                of: normalized, isRemote: false, before: entry.timestamp)
            {
                entries.remove(at: echoIndex)
            }
            entries.append(entry)
            return true
        }
    }

    /// Finds the most recent entry within `echoSuppressionWindow` of `timestamp`
    /// that originates from the requested track (`isRemote`) and whose text is
    /// similar enough to `normalizedText` to be the same utterance.
    private func recentEchoMatchIndex(
        of normalizedText: String,
        isRemote: Bool,
        before timestamp: Date
    ) -> Int? {
        for index in entries.indices.reversed() {
            let candidate = entries[index]
            // Entries are appended in chronological order, so once we pass the
            // window boundary every earlier entry is also out of range.
            if timestamp.timeIntervalSince(candidate.timestamp) > Self.echoSuppressionWindow {
                break
            }
            guard candidate.speaker.isRemote == isRemote else { continue }
            let candidateNormalized = Self.normalizedForComparison(candidate.text)
            if Self.similarity(normalizedText, candidateNormalized) >= Self.echoSimilarityThreshold
            {
                return index
            }
        }
        return nil
    }

    /// Lowercases, strips punctuation, and collapses whitespace so that two
    /// transcriptions of the same speech compare equal despite cosmetic
    /// differences (capitalization, trailing punctuation, extra spaces).
    static func normalizedForComparison(_ text: String) -> String {
        let scalars = text.lowercased().unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }

    /// Similarity of two strings in 0...1, derived from Levenshtein edit distance
    /// normalized by the longer string's length (1 = identical).
    static func similarity(_ a: String, _ b: String) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let lhs = Array(a)
        let rhs = Array(b)
        let maxLength = max(lhs.count, rhs.count)
        guard maxLength > 0 else { return 1 }
        return 1 - Double(levenshtein(lhs, rhs)) / Double(maxLength)
    }

    /// Standard two-row Levenshtein edit distance.
    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,  // deletion
                    current[j - 1] + 1,  // insertion
                    previous[j - 1] + cost  // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Shared time formatter for transcript display (HH:mm:ss).
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    /// Formats a date as HH:mm:ss for transcript display.
    static func formatTime(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// Formats the entire transcript as plain text for export.
    func asPlainText() -> String {
        entries.map { entry in
            let time = Self.formatTime(entry.timestamp)
            return "[\(time)] \(entry.speaker.displayName): \(entry.text)"
        }.joined(separator: "\n")
    }

    /// Duration of the meeting so far.
    var duration: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    /// Formatted duration string (e.g. "12:34").
    var formattedDuration: String {
        let total = Int(duration)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
