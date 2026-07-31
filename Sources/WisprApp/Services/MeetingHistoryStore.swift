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

    /// Retitles an archived session and writes it back.
    ///
    /// The file on disk is renamed to match, so the name given here is the name
    /// the user sees in Finder. Pass `nil` or a blank string to clear the title,
    /// which falls the session — and its filename — back to the session's date.
    func retitle(_ summary: TranscriptSummary, to title: String?) async {
        let url = summary.url

        // Edit the file rather than `loadedTranscript`: a session can be renamed
        // from the sidebar without being opened first.
        let outcome = await Task.detached { () -> Result<(MeetingTranscript, URL), any Error> in
            do {
                var transcript = try TranscriptStore.load(url)
                transcript.setTitle(title)
                try TranscriptStore.save(transcript, to: url)
                // Rename only after the content is safely written: a failed rename
                // then leaves a correctly-titled file under its old name, rather
                // than a renamed file holding a stale title.
                let renamed = try TranscriptStore.rename(
                    at: url, startTime: transcript.startTime, title: transcript.title)
                return .success((transcript, renamed))
            } catch {
                return .failure(error)
            }
        }.value

        switch outcome {
        case .success(let (transcript, renamedURL)):
            // The URL is a row's identity, so the rename has to be reflected in the
            // selection — otherwise the transcript the user is reading would look
            // as though it had been deleted.
            if loadedURL == url {
                selection = .archived(renamedURL)
                loadedTranscript = transcript
            }
            await refresh()
        case .failure(let error):
            Log.stateManager.error(
                "MeetingHistoryStore — retitle failed: \(error.localizedDescription)")
            errorMessage = "Could not rename this session: \(error.localizedDescription)"
        }
    }

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
        await delete([summary])
    }

    /// Deletes several archived transcripts in one pass.
    ///
    /// A failure on one file does not abort the rest: stopping halfway would leave
    /// the user unsure which transcripts actually went. Every failure is collected
    /// and reported together.
    func delete(_ summaries: [TranscriptSummary]) async {
        guard !summaries.isEmpty else { return }
        let urls = summaries.map(\.url)

        let failures = await Task.detached { () -> [String] in
            var failures: [String] = []
            for url in urls {
                do {
                    try TranscriptStore.delete(url)
                } catch {
                    failures.append("\(url.lastPathComponent) (\(error.localizedDescription))")
                }
            }
            return failures
        }.value

        // Drop the viewer off a transcript that no longer exists before rescanning.
        if let loaded = loadedURL, urls.contains(loaded) { showLive() }
        await refresh()

        guard !failures.isEmpty else { return }
        Log.stateManager.error(
            "MeetingHistoryStore — delete failed for \(failures.count) of \(urls.count) files")
        errorMessage = failures.count == 1
            ? "Could not delete \(failures[0])."
            : "Could not delete \(failures.count) transcripts: \(failures.joined(separator: ", "))."
    }

    // MARK: - External Changes

    /// The folder currently being listed.
    ///
    /// Observable so the view can re-arm its folder watch when the user picks a
    /// different location in Settings.
    private(set) var directory: URL = TranscriptStore.directory

    /// Rescans when the user changes the transcripts folder in Settings.
    ///
    /// Summaries are keyed by file URL, so without this the list keeps the previous
    /// folder's URLs and every action — opening, revealing in Finder, deleting —
    /// operates on the old location.
    func followLocationChanges() async {
        for await newDirectory in TranscriptLocation.changes() {
            guard !Task.isCancelled else { return }
            directory = newDirectory
            showLive()
            await refresh()
        }
    }

    /// Keeps the history list in step with the transcripts folder on disk.
    ///
    /// Transcripts deleted or renamed in Finder would otherwise leave stale rows
    /// in the sidebar. Runs for as long as the calling task lives — the meeting
    /// window's lifetime — so nothing is watched while the window is closed; the
    /// window's own `refresh()` on appear covers anything missed in between.
    func watchForExternalChanges() async {
        while !Task.isCancelled {
            for await _ in TranscriptDirectoryWatcher.changes(for: TranscriptStore.directory) {
                // A single Finder action emits several vnode events. Pausing lets
                // them collapse into one rescan, since the stream keeps only the
                // newest pending element.
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                await refresh()
            }

            guard !Task.isCancelled else { return }
            // The stream ended because the folder itself was moved or deleted.
            // Pause before re-watching so a missing folder cannot spin the loop.
            try? await Task.sleep(for: .seconds(1))
        }
    }

    /// Clears a surfaced error once the user has seen it.
    func dismissError() {
        errorMessage = nil
    }
}
