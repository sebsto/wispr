//
//  WhisperProgressCallbackTests.swift
//  wisprTests
//
//  Tests for the progress events WhisperService derives from WhisperKit's
//  callbacks.
//
//  WhisperKit starts each decoding window where the previous one stopped, and
//  that point is the last timestamp it found, so a window usually advances by
//  less than its 30 s length. The number of windows decoded therefore says
//  nothing reliable about how much audio has been covered. These tests replay
//  that behaviour and check that no event claims more audio than was decoded.
//

import Testing
import Foundation
@preconcurrency import WhisperKit
@testable import WisprCore

@Suite("Whisper progress callbacks")
struct WhisperProgressCallbackTests {

    /// Collects every update the callbacks emit.
    private nonisolated final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _updates: [ProgressUpdate] = []

        func record(_ update: ProgressUpdate) {
            lock.lock()
            _updates.append(update)
            lock.unlock()
        }

        var updates: [ProgressUpdate] {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }
    }

    @Test("Progress never runs ahead of the audio actually decoded")
    func progressNeverExceedsDecodedAudio() {
        // A 1h38m file where every window advances 24 s instead of 30 s.
        let audioDuration = 5880.0
        let advancePerWindow = 24.0
        let windowCount = Int(audioDuration / advancePerWindow)

        let recorder = Recorder()
        let callbacks = WhisperService.makeProgressCallbacks(
            audioDuration: audioDuration,
            onProgress: { recorder.record($0) }
        )

        var checked = 0
        for window in 0..<windowCount {
            let decodedBefore = Double(window) * advancePerWindow

            // Tokens of window `window` are being decoded: only `decodedBefore`
            // seconds of audio have been covered so far.
            let progress = TranscriptionProgress(
                timings: TranscriptionTimings(),
                text: "",
                tokens: [],
                windowId: window
            )
            _ = callbacks.token?(progress)

            let fresh = recorder.updates.dropFirst(checked)
            checked += fresh.count
            for update in fresh {
                #expect(
                    update.processedSeconds <= decodedBefore + 0.001,
                    "window \(window): reported \(update.processedSeconds) s but only \(decodedBefore) s are decoded"
                )
            }

            // The window finishes and WhisperKit reports its segments.
            let segment = TranscriptionSegment(
                start: Float(decodedBefore),
                end: Float(decodedBefore + advancePerWindow),
                text: "x"
            )
            callbacks.segment?([segment])
        }
    }

    @Test("A finished window reports the end of its last segment")
    func segmentEndIsReported() {
        let recorder = Recorder()
        let callbacks = WhisperService.makeProgressCallbacks(
            audioDuration: 100,
            onProgress: { recorder.record($0) }
        )

        callbacks.segment?([
            TranscriptionSegment(start: 0, end: 10, text: "a"),
            TranscriptionSegment(start: 10, end: 24, text: "b"),
        ])

        #expect(recorder.updates.last?.processedSeconds == 24)
        #expect(recorder.updates.last?.totalSeconds == 100)
    }

    @Test("No handler means no callbacks")
    func noHandlerMeansNoCallbacks() {
        let callbacks = WhisperService.makeProgressCallbacks(audioDuration: 100, onProgress: nil)
        #expect(callbacks.token == nil)
        #expect(callbacks.segment == nil)
    }
}
