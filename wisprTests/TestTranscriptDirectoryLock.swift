//
//  TestTranscriptDirectoryLock.swift
//  wisprTests
//
//  Serializes the test suites that share the transcripts directory.
//

import Foundation
import Testing

/// Serializes access to the process-wide transcripts directory.
///
/// `.serialized` only orders tests *within* one suite, and several suites here
/// touch the same directory: some read and write transcripts through
/// `TranscriptStore`, while `TranscriptLocationTests` redirects the whole process
/// to a temporary folder. Run in parallel, a redirect lands mid-way through
/// another suite's test, whose `refresh()` then scans the wrong folder and reports
/// the transcript it just wrote as missing.
///
/// An actor with an explicit waiter queue rather than a plain actor method: actors
/// are reentrant at `await`, so an `async` body would let a second caller in while
/// the first is suspended — exactly what has to be prevented here.
actor TestTranscriptDirectoryLock {
    static let shared = TestTranscriptDirectoryLock()

    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Takes exclusive use of the transcripts directory, waiting if it is in use.
    ///
    /// Exposed as a bare acquire/release pair rather than a closure-taking method:
    /// passing a test's non-`Sendable` body into an actor would cross isolation
    /// domains, which Swift 6 rejects.
    func acquire() async {
        while isHeld {
            await withCheckedContinuation { waiters.append($0) }
        }
        isHeld = true
    }

    func release() {
        isHeld = false
        guard !waiters.isEmpty else { return }
        waiters.removeFirst().resume()
    }
}

/// Gives every test in a suite exclusive use of the transcripts directory.
///
/// Applied as a trait rather than wrapped around each helper so that tests which
/// touch the directory without going through a helper are covered too — the
/// process-wide redirect in `TranscriptLocationTests` affects all of them.
struct TranscriptDirectoryIsolation: SuiteTrait, TestTrait, TestScoping {
    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: () async throws -> Void
    ) async throws {
        let lock = TestTranscriptDirectoryLock.shared
        await lock.acquire()
        do {
            try await function()
        } catch {
            await lock.release()
            throw error
        }
        await lock.release()
    }
}

extension Trait where Self == TranscriptDirectoryIsolation {
    /// Serializes the suite against every other suite that shares the transcripts
    /// directory.
    static var transcriptDirectoryIsolated: Self { Self() }
}
