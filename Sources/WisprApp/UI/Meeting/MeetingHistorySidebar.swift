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

    /// Summary pending delete confirmation. Deletion is irreversible — there is
    /// no audio to re-transcribe from — so it is always confirmed.
    @State private var pendingDeletion: TranscriptSummary?

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
        List(selection: selectionBinding) {
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
                                Divider()
                                Button {
                                    revealInFinder(summary.url)
                                } label: {
                                    Label("Show in Finder", systemImage: SFSymbols.folder)
                                }
                                Button(role: .destructive) {
                                    pendingDeletion = summary
                                } label: {
                                    Label("Delete…", systemImage: SFSymbols.delete)
                                }
                            }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .task { await history.refresh() }
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
            "Delete this transcript?",
            isPresented: deletionPrompt,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { summary in
            Button("Delete", role: .destructive) {
                Task { await history.delete(summary) }
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("This cannot be undone — wispr keeps no audio to re-transcribe from.")
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

    /// Bridges `List` selection to the store, loading the transcript on change.
    ///
    /// A plain binding to `history.selection` would change the highlight without
    /// loading anything, so selection is routed through the store's async loader.
    private var selectionBinding: Binding<TranscriptSelection?> {
        Binding(
            get: { history.selection },
            set: { newValue in
                guard let newValue, newValue != history.selection else { return }
                switch newValue {
                case .live:
                    history.showLive()
                case .archived(let url):
                    guard let summary = history.summaries.first(where: { $0.url == url })
                    else { return }
                    Task { await history.show(summary) }
                }
            }
        )
    }

    private var deletionPrompt: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
