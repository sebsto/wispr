//
//  MeetingHistorySidebar.swift
//  wispr
//
//  Sidebar listing past meeting transcripts, with the live session pinned on top.
//

import AppKit
import SwiftUI

/// Lists saved meeting transcripts and lets one be opened, renamed, or deleted.
///
/// Deliberately a plain column rather than a `NavigationSplitView` sidebar. The
/// split view supplies its own collapse button, and that button moves between
/// the leading and trailing edge of the title bar depending on whether the
/// sidebar is open; owning the visibility state keeps the toggle in one place.
struct MeetingHistorySidebar: View {
    @Environment(MeetingStateManager.self) private var meetingState: MeetingStateManager
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    let history: MeetingHistoryStore

    /// Session awaiting delete confirmation. Deletion is irreversible, so it is
    /// always confirmed.
    @State private var pendingDeletion: TranscriptSummary?

    /// Session being retitled, and the in-flight text.
    @State private var editingURL: URL?
    @State private var editingTitle = ""

    /// Focuses the rename field as it appears, so a name can be typed straight
    /// away instead of having to click into the visible box first.
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    liveRow
                }

                if !history.summaries.isEmpty {
                    Section("History") {
                        ForEach(history.summaries) { summary in
                            historyRow(summary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if let message = history.errorMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 190, idealWidth: 210, maxWidth: 280)
        .task { history.refresh() }
        .confirmationDialog(
            "Delete this transcript?",
            isPresented: deletionPresented,
            presenting: pendingDeletion
        ) { summary in
            Button("Delete", role: .destructive) {
                history.delete(summary)
                pendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { _ in
            Text("wispr keeps no audio, so the transcript cannot be recreated.")
        }
    }

    // MARK: - Live Row

    private var liveRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(meetingState.meetingState == .recording ? Color.red : Color.secondary)
                    .frame(width: 7, height: 7)

                Text("Current Session")
                    .font(.callout.weight(.medium))
            }

            Text(entryCountLabel(meetingState.transcript.entries.count))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { history.showLive() }
        .listRowBackground(rowBackground(isSelected: !history.isShowingArchived))
    }

    // MARK: - History Row

    @ViewBuilder
    private func historyRow(_ summary: TranscriptSummary) -> some View {
        let isSelected = history.selection == .archived(summary.url)

        VStack(alignment: .leading, spacing: 2) {
            if editingURL == summary.url {
                TextField("Session name", text: $editingTitle)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                    .focused($titleFieldFocused)
                    .onAppear { titleFieldFocused = true }
                    .onSubmit { commitRename(summary) }
                    .onExitCommand { cancelRename() }
            } else {
                Text(summary.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
            }

            Text("\(summary.formattedSpan) · \(entryCountLabel(summary.entryCount))")
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { history.show(summary) }
        .listRowBackground(rowBackground(isSelected: isSelected))
        .contextMenu {
            Button("Rename…") { beginRename(summary) }
            if summary.title != nil {
                Button("Use Date as Name") { history.rename(summary, to: nil) }
            }
            Divider()
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([summary.url])
            }
            Divider()
            Button("Delete…", role: .destructive) { pendingDeletion = summary }
        }
    }

    // MARK: - Rename

    private func beginRename(_ summary: TranscriptSummary) {
        editingTitle = summary.title ?? ""
        editingURL = summary.url
    }

    private func commitRename(_ summary: TranscriptSummary) {
        history.rename(summary, to: editingTitle)
        cancelRename()
    }

    private func cancelRename() {
        editingURL = nil
        editingTitle = ""
        titleFieldFocused = false
    }

    // MARK: - Chrome

    private func entryCountLabel(_ count: Int) -> String {
        count == 1 ? "1 entry" : "\(count) entries"
    }

    private func rowBackground(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isSelected ? theme.accentColor.opacity(0.18) : Color.clear)
    }

    /// `confirmationDialog` needs a `Bool` binding; the pending session is the
    /// real state, so this projects one from it.
    private var deletionPresented: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }
}
