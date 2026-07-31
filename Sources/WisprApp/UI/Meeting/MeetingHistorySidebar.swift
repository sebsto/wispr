//
//  MeetingHistorySidebar.swift
//  wispr
//
//  Sidebar listing past meeting transcripts, with the live session pinned on top.
//

import SwiftUI
import WisprCore

/// Sidebar for the meeting window: the live session followed by saved transcripts.
struct MeetingHistorySidebar: View {
    @Environment(MeetingStateManager.self) private var meetingState: MeetingStateManager
    @Environment(MeetingHistoryStore.self) private var history: MeetingHistoryStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// Summaries pending delete confirmation — one row, or a whole multi-selection.
    /// Deletion is irreversible (there is no audio to re-transcribe from), so it is
    /// always confirmed. Empty means no prompt is showing.
    @State private var pendingDeletion: [TranscriptSummary] = []

    /// Rows highlighted in the list. Multi-selection exists for bulk delete; the
    /// *displayed* transcript still follows a single row (see `syncDisplay`).
    @State private var selectedRows: Set<TranscriptSelection> = [.live]

    /// Session being retitled, and the in-flight text.
    @State private var editingTitleURL: URL?
    @State private var editingTitle = ""
    /// Focuses the retitle field as soon as it appears so the user can type
    /// straight away rather than having to click into the visible box.
    @FocusState private var titleFieldFocused: Bool

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        List(selection: $selectedRows) {
            Section {
                liveRow
                    .tag(TranscriptSelection.live)
            }

            if !history.summaries.isEmpty {
                Section("History") {
                    ForEach(history.summaries) { summary in
                        historyRow(summary)
                            .tag(TranscriptSelection.archived(summary.url))
                            .contextMenu {
                                contextMenu(for: summary)
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        // The Delete key acts on the whole selection, matching Finder.
        .onDeleteCommand {
            let targets = selectedSummaries
            guard !targets.isEmpty else { return }
            pendingDeletion = targets
        }
        .task { await history.refresh() }
        .task { await history.followLocationChanges() }
        // Keyed on the folder so changing it in Settings re-arms the watch on the
        // new location instead of leaving it on the old one.
        .task(id: history.directory) { await history.watchForExternalChanges() }
        .onChange(of: selectedRows) { _, rows in
            syncDisplay(to: rows)
        }
        // Mirror moves the store makes on its own — a finished meeting, or a
        // deletion falling back to the live session — without clobbering an
        // in-progress multi-selection.
        .onChange(of: history.selection) { _, selection in
            guard selectedRows.count <= 1, selectedRows.first != selection else { return }
            selectedRows = [selection]
        }
        // A finished meeting becomes a new file on disk; pick it up so the user
        // does not have to reopen the window to see it, then jump straight to it
        // so "Current Session" is not left showing the now-archived transcript.
        .onChange(of: meetingState.meetingState) { old, new in
            if old == .recording, new != .recording {
                Task {
                    await history.refresh()
                    if let url = meetingState.lastSavedURL,
                        let summary = history.summaries.first(where: { $0.url == url })
                    {
                        await history.show(summary)
                    }
                }
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: deletionPrompt,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let targets = pendingDeletion
                pendingDeletion = []
                Task { await history.delete(targets) }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = [] }
        } message: {
            Text("This cannot be undone — wispr keeps no audio to re-transcribe from.")
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func contextMenu(for summary: TranscriptSummary) -> some View {
        let targets = deletionTargets(for: summary)

        // Renaming is inherently single-row — one name cannot apply to several
        // sessions — so it is hidden rather than silently acting on just one.
        if targets.count == 1 {
            Button {
                beginRetitle(summary)
            } label: {
                Label("Rename…", systemImage: SFSymbols.rename)
            }
            if summary.hasTitle {
                Button {
                    Task { await history.retitle(summary, to: nil) }
                } label: {
                    Label("Use Date as Name", systemImage: SFSymbols.rename)
                }
            }
        }

        Divider()

        Button {
            revealInFinder(targets.map(\.url))
        } label: {
            Label("Show in Finder", systemImage: SFSymbols.folder)
        }

        Button(role: .destructive) {
            pendingDeletion = targets
        } label: {
            Label(
                targets.count == 1 ? "Delete…" : "Delete \(targets.count) Transcripts…",
                systemImage: SFSymbols.delete
            )
        }
    }

    // MARK: - Rows

    private var liveRow: some View {
        let isRecording = meetingState.meetingState == .recording
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Circle()
                    .fill(isRecording ? Color.red : Color.secondary.opacity(0.4))
                    .frame(width: 7, height: 7)
                Text(isRecording ? "Recording" : "Current Session")
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }
            Text(
                isRecording
                    ? meetingState.elapsedTime
                    : "\(meetingState.transcript.entries.count) entries"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            isRecording
                ? "Live session, recording, \(meetingState.elapsedTime)"
                : "Current session, \(meetingState.transcript.entries.count) entries")
    }

    private func historyRow(_ summary: TranscriptSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if editingTitleURL == summary.url {
                TextField("Session name", text: $editingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .focused($titleFieldFocused)
                    .onAppear { titleFieldFocused = true }
                    .onSubmit { commitRetitle(summary) }
                    .onExitCommand { cancelRetitle() }
                    .accessibilityLabel("Name for this session")
            } else {
                Text(displayTitle(for: summary))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            // Keep the date visible once a title replaces it in the headline.
            if summary.hasTitle, editingTitleURL != summary.url {
                Text(Self.dateFormatter.string(from: summary.startTime))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

            if summary.isUnreadable {
                // Shown rather than hidden, so a corrupt file can be deleted
                // instead of looking like it silently disappeared.
                Label("Unreadable file", systemImage: SFSymbols.warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Text(subtitle(for: summary))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if !summary.preview.isEmpty {
                    Text(summary.preview)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: summary))
    }

    /// Headline for a session: its name if it has one, otherwise its date.
    private func displayTitle(for summary: TranscriptSummary) -> String {
        if let title = summary.title, !title.isEmpty { return title }
        return Self.dateFormatter.string(from: summary.startTime)
    }

    private func beginRetitle(_ summary: TranscriptSummary) {
        // Pre-fill with the assigned title only; the date placeholder would
        // otherwise have to be deleted before typing.
        editingTitle = summary.title ?? ""
        editingTitleURL = summary.url
    }

    private func cancelRetitle() {
        editingTitleURL = nil
        editingTitle = ""
    }

    private func commitRetitle(_ summary: TranscriptSummary) {
        let title = editingTitle
        cancelRetitle()
        Task { await history.retitle(summary, to: title) }
    }

    private func subtitle(for summary: TranscriptSummary) -> String {
        var parts = [summary.formattedDuration, "\(summary.entryCount) entries"]
        if !summary.speakerNames.isEmpty {
            parts.append(summary.speakerNames.joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private func accessibilityLabel(for summary: TranscriptSummary) -> String {
        let name = displayTitle(for: summary)
        guard !summary.isUnreadable else { return "\(name), unreadable file" }
        return "\(name), \(summary.formattedDuration), \(summary.entryCount) entries"
    }

    // MARK: - Selection plumbing

    /// Archived summaries in the current selection.
    ///
    /// `.live` is filtered out — there is no file behind it to act on — and rows
    /// whose file has since disappeared are dropped rather than passed on.
    private var selectedSummaries: [TranscriptSummary] {
        selectedRows.compactMap { row in
            guard case .archived(let url) = row else { return nil }
            return history.summaries.first { $0.url == url }
        }
    }

    /// What a destructive action on `summary` should apply to.
    ///
    /// Acting inside a multi-selection takes the whole selection; acting on a row
    /// outside it takes just that row. This is how Finder behaves, and it stops a
    /// right-click on an unselected row from deleting something else.
    private func deletionTargets(for summary: TranscriptSummary) -> [TranscriptSummary] {
        let selected = selectedSummaries
        guard selected.count > 1, selected.contains(summary) else { return [summary] }
        return selected
    }

    /// Loads the transcript for a single-row selection.
    ///
    /// Multi-selection deliberately leaves the viewer untouched: there is no
    /// sensible "current transcript" for several rows, and swapping the pane on
    /// every shift-click would make range selection unusable.
    private func syncDisplay(to rows: Set<TranscriptSelection>) {
        guard rows.count == 1, let only = rows.first, only != history.selection else { return }

        switch only {
        case .live:
            history.showLive()
        case .archived(let url):
            guard let summary = history.summaries.first(where: { $0.url == url }) else { return }
            Task { await history.show(summary) }
        }
    }

    private var deletionTitle: String {
        pendingDeletion.count == 1
            ? "Delete this transcript?"
            : "Delete \(pendingDeletion.count) transcripts?"
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { !pendingDeletion.isEmpty },
            set: { if !$0 { pendingDeletion = [] } }
        )
    }

    private func revealInFinder(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }
}
