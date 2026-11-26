//
//  TranscriptMarkdownRenderer.swift
//  wispr
//
//  Turns a meeting transcript into a plain Markdown document that note-taking
//  apps can open directly.
//

import Foundation

/// Renders a `MeetingTranscript` as Markdown, optionally preceded by a YAML
/// properties block.
///
/// The output is plain Markdown with no app-specific syntax, so every export
/// destination receives the same document.
nonisolated enum TranscriptMarkdownRenderer {

    /// Renders `transcript`.
    ///
    /// - Parameters:
    ///   - transcript: The meeting to render.
    ///   - includeFrontmatter: Whether to start the file with a YAML block holding
    ///     the title, date, source, duration, and speakers.
    static func render(_ transcript: MeetingTranscript, includeFrontmatter: Bool) -> String {
        let title = displayTitle(for: transcript)
        var lines: [String] = []

        if includeFrontmatter {
            lines.append("---")
            lines.append("title: \(quoted(title))")
            lines.append("date: \(isoDate(transcript.startTime))")
            lines.append("source: wispr")
            lines.append("duration: \(quoted(transcript.formattedContentDuration))")
            let speakers = speakerNames(in: transcript).map(quoted).joined(separator: ", ")
            lines.append("speakers: [\(speakers)]")
            lines.append("---")
            lines.append("")
        }

        lines.append("# \(singleLine(title))")
        lines.append("")

        for entry in transcript.entries {
            let offset = MeetingTranscript.formatDuration(
                entry.timestamp.timeIntervalSince(transcript.startTime))
            let speaker = singleLine(transcript.displayName(for: entry.speaker))
            lines.append("**\(speaker)** (\(offset)): \(singleLine(entry.text))")
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    /// The title to show: the user's title, or the start date when there is none.
    static func displayTitle(for transcript: MeetingTranscript) -> String {
        if let title = transcript.title, !title.isEmpty {
            return singleLine(title)
        }
        return "Meeting \(titleDateFormatter.string(from: transcript.startTime))"
    }

    // MARK: - Helpers

    /// Speaker labels in order of first appearance, with user-assigned names applied.
    private static func speakerNames(in transcript: MeetingTranscript) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []
        for entry in transcript.entries {
            let name = singleLine(transcript.displayName(for: entry.speaker))
            if seen.insert(name).inserted { ordered.append(name) }
        }
        return ordered
    }

    /// A YAML double-quoted string, so values containing `:`, `#`, or quotes stay valid.
    private static func quoted(_ value: String) -> String {
        let escaped = singleLine(value)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Collapses line breaks into spaces so a value cannot break out of its line.
    private static func singleLine(_ value: String) -> String {
        value
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Local time without a zone suffix, the form note apps recognise as a date and time.
    private static func isoDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: date)
    }

    private static var titleDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}
