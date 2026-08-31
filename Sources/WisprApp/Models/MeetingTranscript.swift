//
//  MeetingTranscript.swift
//  wispr
//
//  Data model for meeting transcription entries with speaker labels.
//

import Foundation

/// How a meeting is captured, which determines the speaker model.
///
/// - `online`: the classic remote-meeting shape. Your voice is on the mic and
///   everyone else arrives through system audio; the mic track is labelled
///   "You" and only the system track is diarized.
/// - `inPerson`: everyone is in one room and reaches the same microphone. There
///   is no privileged "You" — the mic track itself is diarized and every
///   participant (including the local user) becomes a numbered speaker. System
///   audio is not captured, so no Screen Recording permission is needed.
///
/// Diarization can distinguish up to four participants in person, a fixed limit
/// of the underlying Sortformer model.
nonisolated enum MeetingMode: String, Sendable, Codable, CaseIterable {
    case online
    case inPerson
}

/// Identifies the audio source / speaker in a meeting transcript.///
/// Speaker indices are stored **0-based** internally. The +1 transform to
/// "Speaker 1", "Speaker 2", etc. happens only inside `displayName`.
/// `nonisolated` so its `Codable` conformance is usable off the main actor. Under
/// this package's `.defaultIsolation(MainActor.self)`, an unannotated conformance
/// is a *MainActor-isolated conformance*, which cannot be used from a
/// `nonisolated` context — decoding a transcript off the main thread would not
/// compile.
nonisolated enum MeetingSpeaker: Sendable, Equatable, Hashable, Codable {
    case you
    /// Remote participant. `speakerIndex` is nil during Sortformer's cold-start
    /// window or when diarization is disabled — renders as plain "Others".
    case others(speakerIndex: Int?)

    /// User-visible label for transcript display and plain-text export.
    ///
    /// Falls back to the generic "Speaker N" form. Callers holding a transcript
    /// should prefer `MeetingTranscript.displayName(for:)`, which resolves
    /// user-assigned names.
    var displayName: String {
        switch self {
        case .you: return "You"
        case .others(.none): return "Others"
        case .others(.some(let index)): return "Speaker \(index + 1)"
        }
    }

    /// The diarization index of a remote speaker, or `nil` for "You" and for
    /// remote entries recorded before diarization resolved a speaker.
    var speakerIndex: Int? {
        if case .others(.some(let index)) = self { return index }
        return nil
    }

    /// Whether this speaker is a remote participant (system-audio track),
    /// regardless of the resolved diarization index.
    var isRemote: Bool {
        if case .others = self { return true }
        return false
    }
}

/// A single timestamped entry in a meeting transcript.
nonisolated struct MeetingTranscriptEntry: Identifiable, Sendable, Equatable, Codable {
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
nonisolated struct MeetingTranscript: Sendable, Equatable, Codable {
    var entries: [MeetingTranscriptEntry] = []
    let startTime: Date

    /// How this session was captured. Fixed at `startMeeting()` and never changed
    /// mid-session, so a transcript never mixes two labelling schemes. Archived
    /// transcripts written before this field existed decode as `.online`.
    var mode: MeetingMode = .online

    /// User-assigned title for the session, or `nil` to fall back to its date.
    ///
    /// A meeting's date is a poor handle once there are more than a handful of
    /// them; "Sprint review" is what makes a transcript findable again.
    var title: String?

    /// User-assigned names for diarized speakers, keyed by the **string form of
    /// the 0-based speaker index** (`"0"`, `"1"`, …).
    ///
    /// String keys rather than `Int` because `[Int: String]` encodes to
    /// string-keyed JSON anyway, and using them directly keeps the on-disk shape
    /// explicit. Names are resolved at display time and never stored per entry, so
    /// renaming a speaker retroactively relabels every one of their entries.
    var speakerNames: [String: String] = [:]

    init(startTime: Date = Date()) {
        self.startTime = startTime
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case entries, startTime, speakerNames, title, mode
    }

    /// Decodes a transcript, tolerating files written before `speakerNames` and
    /// `title` existed.
    ///
    /// This initializer is not optional politeness: the compiler-synthesized
    /// `init(from:)` calls `decode(_:forKey:)` for every non-optional stored
    /// property and **ignores the default-value expression**. Relying on `= [:]`
    /// would make every previously-saved transcript fail to decode with
    /// `keyNotFound`.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.entries = try container.decode([MeetingTranscriptEntry].self, forKey: .entries)
        self.startTime = try container.decode(Date.self, forKey: .startTime)
        self.speakerNames =
            try container.decodeIfPresent([String: String].self, forKey: .speakerNames) ?? [:]
        self.title = try container.decodeIfPresent(String.self, forKey: .title)
        self.mode = try container.decodeIfPresent(MeetingMode.self, forKey: .mode) ?? .online
    }

    // MARK: - Title

    /// Assigns (or clears, when `title` is nil or blank) the session's title.
    mutating func setTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    // MARK: - Speaker Names

    /// The label to display for `speaker`, preferring a user-assigned name.
    func displayName(for speaker: MeetingSpeaker) -> String {
        guard let index = speaker.speakerIndex,
            let name = speakerNames[String(index)],
            !name.isEmpty
        else {
            return speaker.displayName
        }
        return name
    }

    /// Assigns (or clears, when `name` is nil or blank) a diarized speaker's name.
    mutating func setName(_ name: String?, forSpeakerIndex index: Int) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            speakerNames[String(index)] = trimmed
        } else {
            speakerNames.removeValue(forKey: String(index))
        }
    }

    /// Diarization indices present in the transcript, in order of first appearance.
    ///
    /// Drives the speaker roster: only speakers who actually spoke are offered for
    /// renaming.
    var presentSpeakerIndices: [Int] {
        var seen: Set<Int> = []
        var ordered: [Int] = []
        for entry in entries {
            guard let index = entry.speaker.speakerIndex else { continue }
            if seen.insert(index).inserted { ordered.append(index) }
        }
        return ordered
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
    ///
    /// Uses user-assigned speaker names when present.
    func asPlainText() -> String {
        entries.map { entry in
            let time = Self.formatTime(entry.timestamp)
            return "[\(time)] \(displayName(for: entry.speaker)): \(entry.text)"
        }.joined(separator: "\n")
    }

    /// Time elapsed since the meeting started, **relative to now**.
    ///
    /// Only meaningful for a live session. For a transcript loaded from disk use
    /// `contentDuration`, which is anchored to the entries themselves.
    var duration: TimeInterval {
        Date().timeIntervalSince(startTime)
    }

    /// Time span covered by the transcript's entries.
    ///
    /// Unlike `duration`, this is stable once a session ends, so a transcript
    /// reopened days later reports the meeting's real length instead of the time
    /// elapsed since it started.
    var contentDuration: TimeInterval {
        guard let last = entries.last else { return 0 }
        return max(0, last.timestamp.timeIntervalSince(startTime))
    }

    /// Formatted live duration string (e.g. "12:34").
    var formattedDuration: String {
        Self.formatDuration(duration)
    }

    /// Formatted content duration string (e.g. "12:34"), for archived transcripts.
    var formattedContentDuration: String {
        Self.formatDuration(contentDuration)
    }

    /// Formats a duration as `m:ss`, or `h:mm:ss` past an hour.
    static func formatDuration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
