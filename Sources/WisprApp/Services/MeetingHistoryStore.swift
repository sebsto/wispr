//
//  MeetingHistoryStore.swift
//  wispr
//
//  Browsing state for past meeting transcripts: the sidebar list, which
//  transcript is being viewed, and edits written back to archived files.
//

import Foundation
import Observation
import WisprCore
import os

/// Which transcript the meeting window is currently showing.
nonisolated enum TranscriptSelection: Hashable, Sendable {
    /// The live session owned by `MeetingStateManager`.
    case live
    /// A transcript loaded from disk.
    case archived(URL)
}

/// Observable browsing state for the meeting transcript history.
///
/// Keeps the archived transcript strictly separate from the live one. Without
/// that separation, starting a new meeting — which resets
/// `MeetingStateManager.transcript` — would wipe the historical transcript the
/// user was reading.
///
/// All disk work is dispatched off the main actor: `TranscriptStore` is
/// `nonisolated`, but this type is `@MainActor`, so calling it directly would
/// decode every file on the UI thread.
@MainActor
@Observable
final class MeetingHistoryStore {

    // MARK: - State

    /// Saved transcripts, most recent first.
    private(set) var summaries: [TranscriptSummary] = []

    /// Which transcript the window shows. Defaults to the live session.
    var selection: TranscriptSelection = .live

    /// The archived transcript currently loaded, if any.
    private(set) var loadedTranscript: MeetingTranscript?

    /// True while a directory scan or file load is in flight.
    private(set) var isLoading = false

    /// Set when a transcript could not be read or written.
    private(set) var errorMessage: String?

    // MARK: - Derived

    /// URL of the loaded archived transcript, or `nil` when showing the live one.
    var loadedURL: URL? {
        if case .archived(let url) = selection { return url }
        return nil
    }

    /// Whether the archived (read-only-ish) transcript is being shown.
    var isShowingArchived: Bool { loadedURL != nil }

    // MARK: - Listing

    /// Rescans the transcripts directory.
    func refresh() async {
        isLoading = true
        defer { isLoading = false }

        let scanned = await Task.detached { TranscriptStore.list() }.value
        summaries = scanned

        // A transcript deleted outside the app (or by another window) must not
        // leave the view pointing at a file that no longer exists.
        if let url = loadedURL, !scanned.contains(where: { $0.url == url }) {
            showLive()
        }
    }

    // MARK: - Selection

    /// Switches to the live session.
    func showLive() {
        selection = .live
        loadedTranscript = nil
    }

    /// Loads and displays an archived transcript.
    func show(_ summary: TranscriptSummary) async {
        guard !summary.isUnreadable else {
            selection = .archived(summary.url)
            loadedTranscript = nil
            errorMessage = "This transcript file could not be read."
            return
        }

        isLoading = true
        defer { isLoading = false }
        errorMessage = nil

        let url = summary.url
        let result = await Task.detached { () -> Result<MeetingTranscript, any Error> in
            do { return .success(try TranscriptStore.load(url)) } catch { return .failure(error) }
        }.value

        switch result {
        case .success(let transcript):
            selection = .archived(url)
            loadedTranscript = transcript
        case .failure(let error):
            Log.stateManager.error(
                "MeetingHistoryStore — load failed: \(error.localizedDescription)")
            selection = .archived(url)
            loadedTranscript = nil
            errorMessage = "Could not open this transcript: \(error.localizedDescription)"
        }
    }

    // MARK: - Editing

    /// Renames a speaker in the loaded archived transcript and writes it back.
    ///
    /// Persisting immediately (rather than on window close) matches how the live
    /// session behaves and means a crash can never lose a rename.
    func renameSpeaker(index: Int, to name: String?) async {
        guard let url = loadedURL, var transcript = loadedTranscript else { return }

        transcript.setName(name, forSpeakerIndex: index)
        loadedTranscript = transcript

        let snapshot = transcript
        let failure = await Task.detached { () -> (any Error)? in
            do {
                try TranscriptStore.save(snapshot, to: url)
                return nil
            } catch {
                return error
            }
        }.value

        if let failure {
            Log.stateManager.error(
                "MeetingHistoryStore — rename save failed: \(failure.localizedDescription)")
            errorMessage = "Could not save the speaker name: \(failure.localizedDescription)"
            return
        }

        // Keep the sidebar's resolved speaker names in step with the edit.
        await refresh()
    }

    /// Deletes an archived transcript.
    func delete(_ summary: TranscriptSummary) async {
        let url = summary.url
        let failure = await Task.detached { () -> (any Error)? in
            do {
                try TranscriptStore.delete(url)
                return nil
            } catch {
                return error
            }
        }.value

        if let failure {
            Log.stateManager.error(
                "MeetingHistoryStore — delete failed: \(failure.localizedDescription)")
            errorMessage = "Could not delete this transcript: \(failure.localizedDescription)"
            return
        }

        if loadedURL == url { showLive() }
        await refresh()
    }

    /// Clears a surfaced error once the user has seen it.
    func dismissError() {
        errorMessage = nil
    }
}
