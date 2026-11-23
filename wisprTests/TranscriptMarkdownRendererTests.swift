//
//  TranscriptMarkdownRendererTests.swift
//  wisprTests
//
//  Covers the Markdown a meeting transcript is exported as.
//

import Foundation
import Testing

@testable import WisprApp

@Suite("Transcript Markdown renderer Tests")
struct TranscriptMarkdownRendererTests {

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeTranscript(title: String? = "Sprint review") -> MeetingTranscript {
        var transcript = MeetingTranscript(startTime: start)
        transcript.title = title
        transcript.entries = [
            MeetingTranscriptEntry(
                speaker: .you, text: "Hello everyone.", timestamp: start.addingTimeInterval(5)),
            MeetingTranscriptEntry(
                speaker: .others(speakerIndex: 0), text: "Hi there.",
                timestamp: start.addingTimeInterval(65)),
        ]
        return transcript
    }

    @Test("Frontmatter holds title, date, source, duration and speakers")
    func testFrontmatter() {
        let markdown = TranscriptMarkdownRenderer.render(makeTranscript(), includeFrontmatter: true)
        let lines = markdown.components(separatedBy: "\n")

        #expect(lines[0] == "---")
        #expect(lines[1] == "title: \"Sprint review\"")
        #expect(lines[2].hasPrefix("date: 20"))
        #expect(lines[2].contains("T"))
        #expect(lines[3] == "source: wispr")
        #expect(lines[4] == "duration: \"1:05\"")
        #expect(lines[5] == "speakers: [\"You\", \"Speaker 1\"]")
        #expect(lines[6] == "---")
    }

    @Test("Without frontmatter the file starts with the heading")
    func testNoFrontmatter() {
        let markdown = TranscriptMarkdownRenderer.render(makeTranscript(), includeFrontmatter: false)
        #expect(markdown.hasPrefix("# Sprint review\n"))
        #expect(!markdown.contains("---"))
        #expect(!markdown.contains("source: wispr"))
    }

    @Test("Each entry is a speaker line with its offset from the start")
    func testEntries() {
        let markdown = TranscriptMarkdownRenderer.render(makeTranscript(), includeFrontmatter: false)
        #expect(markdown.contains("**You** (0:05): Hello everyone."))
        #expect(markdown.contains("**Speaker 1** (1:05): Hi there."))
        let first = markdown.range(of: "Hello everyone.")!.lowerBound
        let second = markdown.range(of: "Hi there.")!.lowerBound
        #expect(first < second)
    }

    @Test("User-assigned speaker names are used")
    func testRenamedSpeaker() {
        var transcript = makeTranscript()
        transcript.setName("Alice", forSpeakerIndex: 0)
        let markdown = TranscriptMarkdownRenderer.render(transcript, includeFrontmatter: true)
        #expect(markdown.contains("**Alice** (1:05): Hi there."))
        #expect(markdown.contains("speakers: [\"You\", \"Alice\"]"))
    }

    @Test("A title with colons and quotes stays valid YAML")
    func testSpecialCharactersInTitle() {
        let transcript = makeTranscript(title: "Q3: \"roadmap\" # plan\\")
        let markdown = TranscriptMarkdownRenderer.render(transcript, includeFrontmatter: true)
        #expect(markdown.contains("title: \"Q3: \\\"roadmap\\\" # plan\\\\\""))
    }

    @Test("A multi-line title cannot break out of its line")
    func testMultilineTitle() {
        let transcript = makeTranscript(title: "Line one\nauthor: evil")
        let markdown = TranscriptMarkdownRenderer.render(transcript, includeFrontmatter: true)
        #expect(markdown.contains("title: \"Line one author: evil\""))
        #expect(!markdown.contains("\nauthor: evil"))
    }

    @Test("Without a title the heading falls back to the start date")
    func testNoTitle() {
        let markdown = TranscriptMarkdownRenderer.render(
            makeTranscript(title: nil), includeFrontmatter: false)
        #expect(markdown.hasPrefix("# Meeting 20"))
    }

    @Test("Entry text containing line breaks stays on one line")
    func testEntryNewlines() {
        var transcript = makeTranscript()
        transcript.entries = [
            MeetingTranscriptEntry(speaker: .you, text: "one\ntwo", timestamp: start)
        ]
        let markdown = TranscriptMarkdownRenderer.render(transcript, includeFrontmatter: false)
        #expect(markdown.contains("**You** (0:00): one two"))
    }
}
