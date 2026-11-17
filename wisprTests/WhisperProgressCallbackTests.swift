//
//  WhisperProgressCallbackTests.swift
//  wisprTests
//
//  Tests for the progress events WhisperService derives from WhisperKit's
//  segment callback.
//
//  WhisperKit starts each decoding window where the previous one stopped, and
//  that point is the last timestamp it found, so a window usually advances by
//  less than its 30 s length. These tests replay that behaviour and check that
//  the reported position follows the decoded segments, never the window count.
//

import Testing
import Foundation
@preconcurrency import WhisperKit
@testable import WisprCore

@Suite("Whisper progress callbacks")
struct WhisperProgressCallbackTests {

    @Test("Progress follows segment ends and never runs ahead of the decoded audio")
    func progressFollowsSegmentEnds() throws {
        // A 1h38m file where every window advances 24 s instead of 30 s.
        let audioDuration = 5880.0
        let advancePerWindow = 24.0
        let windowCount = Int(audioDuration / advancePerWindow)

        let collector = ProgressUpdateCollector()
        guard let callback = WhisperService.makeSegmentCallback(
            audioDuration: audioDuration,
            onProgress: { collector.record($0) }
        ) else {
            Issue.record("expected a segment callback when a handler is supplied")
            return
        }

        for window in 0..<windowCount {
            let windowStart = Double(window) * advancePerWindow
            let windowEnd = windowStart + advancePerWindow
            callback([
                TranscriptionSegment(start: Float(windowStart), end: Float(windowStart + 10), text: "a"),
                TranscriptionSegment(start: Float(windowStart + 10), end: Float(windowEnd), text: "b"),
            ])

            let latest = try #require(collector.updates.last)
            #expect(latest.processedSeconds == windowEnd)
        }

        #expect(collector.updates.count == windowCount)
        #expect(collector.updates.last?.processedSeconds == Double(windowCount) * advancePerWindow)
        #expect(collector.updates.allSatisfy { $0.totalSeconds == audioDuration })
    }

    @Test("A window reports its furthest segment end and its last text")
    func reportsFurthestSegmentEnd() {
        let collector = ProgressUpdateCollector()
        guard let callback = WhisperService.makeSegmentCallback(
            audioDuration: 100,
            onProgress: { collector.record($0) }
        ) else {
            Issue.record("expected a segment callback when a handler is supplied")
            return
        }

        callback([
            TranscriptionSegment(start: 0, end: 10, text: "a"),
            TranscriptionSegment(start: 10, end: 24, text: "b"),
        ])

        #expect(collector.updates.last?.processedSeconds == 24)
        #expect(collector.updates.last?.textTail == "b")
    }

    @Test("A window with no segments reports nothing")
    func emptyWindowReportsNothing() {
        let collector = ProgressUpdateCollector()
        guard let callback = WhisperService.makeSegmentCallback(
            audioDuration: 100,
            onProgress: { collector.record($0) }
        ) else {
            Issue.record("expected a segment callback when a handler is supplied")
            return
        }

        callback([])

        #expect(collector.updates.isEmpty)
    }

    @Test("No handler means no callback")
    func noHandlerMeansNoCallback() {
        #expect(WhisperService.makeSegmentCallback(audioDuration: 100, onProgress: nil) == nil)
    }
}
