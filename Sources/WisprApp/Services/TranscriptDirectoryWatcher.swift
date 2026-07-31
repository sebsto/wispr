//
//  TranscriptDirectoryWatcher.swift
//  wispr
//
//  Reports changes to the transcripts folder so the history list follows edits
//  made outside the app — above all, files deleted or renamed in Finder.
//

import Foundation
import WisprCore
import os

/// Watches the transcripts folder for changes made behind the app's back.
///
/// Without this, deleting a transcript in Finder leaves a row in the history
/// sidebar that opens nothing, until the window happens to be reopened.
nonisolated enum TranscriptDirectoryWatcher {

    /// Emits once per change to `directory`.
    ///
    /// The stream keeps only the newest element: one Finder action fires several
    /// vnode events, and a consumer only needs to know that *something* changed,
    /// not how many times. Pausing briefly before rescanning (see
    /// `MeetingHistoryStore.watchForExternalChanges`) collapses a burst into a
    /// single directory scan.
    ///
    /// The stream finishes when the folder itself is deleted or moved, because the
    /// descriptor then refers to something that is no longer the transcripts
    /// folder. Callers are expected to re-establish the watch.
    static func changes(for directory: URL) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            // A fresh install has no transcripts folder yet, and opening a missing
            // path fails outright — create it before watching.
            try? FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)

            let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
            guard descriptor >= 0 else {
                Log.stateManager.warning(
                    "TranscriptDirectoryWatcher — cannot watch \(directory.lastPathComponent)")
                continuation.finish()
                return
            }

            let queue = DispatchQueue(label: "com.stormacq.mac.wispr.transcript-watcher")
            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .delete, .rename],
                queue: queue
            )

            // The handler captures `source` — and `source` owns the handler — so the
            // two form a cycle. It is broken by `cancel()` below, which releases the
            // handlers, and cancellation is guaranteed by `onTermination`.
            source.setEventHandler {
                let events = source.data
                continuation.yield()
                if events.contains(.delete) || events.contains(.rename) {
                    continuation.finish()
                }
            }
            source.setCancelHandler { close(descriptor) }
            continuation.onTermination = { _ in source.cancel() }
            source.resume()
        }
    }
}
