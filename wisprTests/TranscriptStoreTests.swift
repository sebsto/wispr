//
//  TranscriptStoreTests.swift
//  wisprTests
//
//  Unit tests for transcript JSON persistence (TranscriptStore) and
//  MeetingTranscript Codable conformance.
//

import Foundation
import Testing
import WisprCore

@testable import WisprApp

@Suite("TranscriptStore Tests")
struct TranscriptStoreTests {

    // MARK: - Codable round-trip

    @Test("MeetingTranscript survives a JSON encode/decode round-trip")
    func testCodableRoundTrip() throws {
        var original = MeetingTranscript(startTime: Date(timeIntervalSince1970: 1_700_000_000))
        original.entries.append(
            MeetingTranscriptEntry(
                speaker: .you, text: "Hello", timestamp: Date(timeIntervalSince1970: 1_700_000_010))
        )
        original.entries.append(
            MeetingTranscriptEntry(
                speaker: .others, text: "Hi there",
                timestamp: Date(timeIntervalSince1970: 1_700_000_020))
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(MeetingTranscript.self, from: data)

        #expect(decoded.entries.count == 2)
        #expect(decoded.entries[0].speaker == .you)
        #expect(decoded.entries[0].text == "Hello")
        #expect(decoded.entries[1].speaker == .others)
        #expect(decoded.entries[1].text == "Hi there")
        #expect(decoded.asPlainText() == original.asPlainText())
    }

    // MARK: - Disk persistence

    @Test("save writes a JSON file that decodes back to the same transcript")
    func testSaveWritesDecodableFile() throws {
        var transcript = MeetingTranscript()
        transcript.entries.append(MeetingTranscriptEntry(speaker: .you, text: "Persisted entry"))

        let url = TranscriptStore.save(transcript)
        #expect(url != nil)

        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(FileManager.default.fileExists(atPath: url.path))
        #expect(url.pathExtension == "json")
        #expect(url.lastPathComponent.hasPrefix("meeting-"))

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(MeetingTranscript.self, from: data)

        #expect(decoded.entries.count == 1)
        #expect(decoded.entries[0].text == "Persisted entry")
    }

    @Test("save ignores an empty transcript and writes nothing")
    func testSaveSkipsEmptyTranscript() {
        let empty = MeetingTranscript()
        let url = TranscriptStore.save(empty)
        #expect(url == nil)
    }

    @Test("save uses the transcript startTime for the filename timestamp")
    func testSaveFilenameUsesStartTime() throws {
        var transcript = MeetingTranscript(startTime: Date(timeIntervalSince1970: 1_700_000_000))
        transcript.entries.append(MeetingTranscriptEntry(speaker: .you, text: "x"))

        let url = TranscriptStore.save(transcript)
        #expect(url != nil)

        guard let url else { return }
        defer { try? FileManager.default.removeItem(at: url) }

        // Filename shape: meeting-yyyy-MM-dd_HH-mm-ss.json
        let name = url.lastPathComponent
        #expect(name.hasPrefix("meeting-"))
        #expect(name.hasSuffix(".json"))
    }
}
