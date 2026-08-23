//
//  MeetingHistoryStore.swift
//  wispr
//
//  Observable state for the meeting history sidebar: which sessions exist,
//  which one is on screen, and the rename/delete operations on them.
//

import Foundation
import Observation
import os

/// What the transcript pane is currently showing.
enum TranscriptSelection: Hashable, Sendable {
    /// The session being recorded now, or the last one recorded this launch.
    case live
    /// A session loaded from disk.
    case archived(URL)
}

/// Owns the list of saved transcripts and the current selection.
///
/// Kept separate from `MeetingStateManager` so that browsing history never
/// touches recording state: opening an old session must not be able to disturb
/// a meeting that is running.
@MainActor
@Observable
final class MeetingHistoryStore {

    // MARK: - Published State

    /// Saved sessions, newest first.
    private(set) var summaries: [TranscriptSummary] = []

    /// Which session the transcript pane shows.
    private(set) var selection: TranscriptSelection = .live

    /// The decoded transcript for an archived selection; `nil` when showing live.
    private(set) var loadedTranscript: MeetingTranscript?

    /// Surfaced in the sidebar when an operation fails, rather than failing silently.
    var errorMessage: String?

    /// Whether an archived session is on screen, as opposed to the live one.
    var isShowingArchived: Bool {
        if case .archived = selection { return true }
        return false
    }

    /// Summary for the current archived selection, if any.
    var selectedSummary: TranscriptSummary? {
        guard case .archived(let url) = selection else { return nil }
        return summaries.first { $0.url == url }
    }

    // MARK: - Loading

    /// Re-reads the transcripts directory.
    ///
    /// If the open archived session has disappeared underneath us (deleted in
    /// Finder, say), the selection falls back to live rather than leaving a
    /// stale transcript on screen.
    func refresh() {
        summaries = TranscriptStore.list()

        if case .archived(let url) = selection,
            !summaries.contains(where: { $0.url == url })
        {
            showLive()
        }
    }

    // MARK: - Selection

    /// Shows the live session.
    func showLive() {
        selection = .live
        loadedTranscript = nil
    }

    /// Loads and shows a saved session, staying put if it cannot be read.
    func show(_ summary: TranscriptSummary) {
        guard let transcript = TranscriptStore.load(summary.url) else {
            errorMessage = "Could not open \(summary.displayName)."
            return
        }
        loadedTranscript = transcript
        selection = .archived(summary.url)
        errorMessage = nil
    }

    // MARK: - Mutating

    /// Names a session, or reverts it to its date when passed `nil`.
    func rename(_ summary: TranscriptSummary, to title: String?) {
        guard let newURL = TranscriptStore.rename(summary.url, to: title) else {
            errorMessage = "Could not rename \(summary.displayName)."
            return
        }

        let wasSelected = (selection == .archived(summary.url))
        refresh()

        // The URL is the row's identity and changes with the slug, so an open
        // session is re-pointed at its new file instead of closing.
        if wasSelected, let moved = summaries.first(where: { $0.url == newURL }) {
            show(moved)
        }
        errorMessage = nil
    }

    /// Deletes a session. Irreversible: wispr keeps no audio to re-transcribe
    /// from, so the caller is expected to have confirmed with the user.
    func delete(_ summary: TranscriptSummary) {
        guard TranscriptStore.delete(summary.url) else {
            errorMessage = "Could not delete \(summary.displayName)."
            return
        }

        if selection == .archived(summary.url) {
            showLive()
        }
        refresh()
        errorMessage = nil
    }

    /// Names a speaker in the session currently on screen, writing it straight
    /// back to that session's file.
    ///
    /// Only meaningful for an archived session: the live transcript is owned by
    /// `MeetingStateManager` and has no file to update until it is saved, which
    /// is also when the user actually knows who was who.
    func renameSpeaker(_ speaker: MeetingSpeaker, to name: String?) {
        guard case .archived(let url) = selection, var transcript = loadedTranscript else {
            return
        }

        transcript.setName(name, for: speaker)

        guard TranscriptStore.save(transcript, to: url) else {
            errorMessage = "Could not save the speaker name."
            return
        }

        loadedTranscript = transcript
        errorMessage = nil
    }
}
