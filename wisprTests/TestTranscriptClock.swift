//
//  TestTranscriptClock.swift
//  wisprTests
//
//  Distinct session start times for tests that write transcript files.
//

import Foundation
import Synchronization

/// Hands out a unique session start time per call.
///
/// The transcript suites all write into the one real transcripts directory and run
/// in parallel. Since a filename is derived from the session's start time, two
/// tests starting within the same second compete for the same name: one save
/// silently lands on the other's file, and one suite's cleanup then deletes a file
/// another suite is still asserting against.
///
/// Times are placed in the distant past so they also cannot collide with the
/// user's own transcripts, and are handed out in increasing order so tests that
/// depend on newest-first ordering still behave.
enum TestTranscriptClock {
    private static let counter = Mutex<Int>(0)

    /// 2000-01-01, far from any real recording.
    private static let base = Date(timeIntervalSince1970: 946_684_800)

    static func nextStart() -> Date {
        let step = counter.withLock { value -> Int in
            value += 1
            return value
        }
        // One second apart: the filename timestamp has second resolution, so
        // anything finer would still collide.
        return base.addingTimeInterval(Double(step))
    }
}
