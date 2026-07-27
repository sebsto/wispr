//
//  MeetingTranscriptView.swift
//  wispr
//
//  Meeting window content: a history sidebar plus the transcript being viewed
//  (the live session, or one loaded from disk).
//

import SwiftUI
import UniformTypeIdentifiers
import WisprCore
import os

/// The main content view for the meeting transcription window.
///
/// Left: history sidebar with the live session pinned on top.
/// Right: recording controls, the transcript, and export actions.
///
/// The displayed transcript is deliberately decoupled from
/// `MeetingStateManager.transcript`: starting a meeting resets the live
/// transcript, which would otherwise wipe an archived one the user was reading.
struct MeetingTranscriptView: View {
    @Environment(MeetingStateManager.self) private var meetingState: MeetingStateManager
    @Environment(MeetingHistoryStore.self) private var history: MeetingHistoryStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    @State private var isExporting = false
    /// Speaker index whose name is being edited, and the in-flight text.
    @State private var editingSpeakerIndex: Int?
    @State private var editingName = ""
    /// Drives keyboard focus into the rename field the moment it appears, so the
    /// user can type immediately instead of having to click the field first.
    @FocusState private var speakerFieldFocused: Bool

    // MARK: - Displayed transcript

    /// The transcript currently on screen — live session or loaded archive.
    private var transcript: MeetingTranscript {
        if history.isShowingArchived {
            return history.loadedTranscript ?? MeetingTranscript()
        }
        return meetingState.transcript
    }

    /// Archived transcripts have no live controls and no auto-scroll.
    private var isArchived: Bool { history.isShowingArchived }

    var body: some View {
        NavigationSplitView {
            MeetingHistorySidebar()
                .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            detailPane
        }
        // Start/Stop lives in the toolbar, next to the sidebar-collapse button,
        // so it stays reachable from anywhere (live or archived) at the very top.
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    Task { await meetingState.toggleMeeting() }
                } label: {
                    Label(
                        meetingState.meetingState == .recording ? "Stop" : "Start Meeting",
                        systemImage: meetingState.meetingState == .recording
                            ? SFSymbols.stopFill
                            : SFSymbols.recordingMicrophone
                    )
                    .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderedProminent)
                .tint(meetingState.meetingState == .recording ? .red : theme.accentColor)
                .accessibilityLabel(
                    meetingState.meetingState == .recording ? "Stop meeting" : "Start meeting")
            }
        }
        // Sized for sidebar + transcript: the rows spend ~154pt on the timestamp
        // and speaker columns before any text, so a narrower window leaves the
        // transcript unreadable.
        .frame(minWidth: 620, minHeight: 420)
        .fileExporter(
            isPresented: $isExporting,
            document: TranscriptDocument(text: transcript.asPlainText()),
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                Log.stateManager.error("Export failed: \(error.localizedDescription)")
            }
        }
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            if showsHeader {
                headerBar
            }

            if let message = history.errorMessage {
                errorBanner(message)
            }

            // Only draw the top divider when something sits above it; otherwise
            // an idle "Current Session" would show an empty bar and stray rule
            // now that Start/Stop lives in the toolbar.
            if showsHeader || history.errorMessage != nil {
                Divider()
            }

            if transcript.entries.isEmpty {
                emptyState
            } else {
                transcriptList
            }

            Divider()

            footerBar
        }
    }

    /// The header shows the archived session's title or the live recording
    /// indicators; when the live session is idle it has nothing to show, so it
    /// (and its divider) are hidden rather than left as an empty bar.
    private var showsHeader: Bool {
        isArchived || meetingState.meetingState == .recording
    }

    private var exportFilename: String {
        guard isArchived else { return "meeting-transcript" }
        let stamp = MeetingTranscript.formatTime(transcript.startTime)
            .replacingOccurrences(of: ":", with: "-")
        return "meeting-transcript-\(stamp)"
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: SFSymbols.warning)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(theme.primaryTextColor)
            Spacer()
            Button {
                history.dismissError()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss message")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.orange.opacity(0.12))
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            if isArchived {
                archivedHeaderContent
            } else {
                liveHeaderContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var liveHeaderContent: some View {
        Spacer()

        if meetingState.meetingState == .recording {
            HStack(spacing: 8) {
                audioLevelIndicator(label: "You", level: meetingState.micLevel, color: .blue)
                audioLevelIndicator(
                    label: "Others", level: meetingState.systemLevel, color: .green)
            }

            Text(meetingState.elapsedTime)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var archivedHeaderContent: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(
                transcript.title
                    ?? transcript.startTime.formatted(date: .abbreviated, time: .shortened)
            )
            .font(.callout.weight(.medium))
            // contentDuration, not duration — the latter is now-relative and
            // would report the time since the meeting started, not its length.
            Text(transcript.formattedContentDuration)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }

        Spacer()

        if meetingState.meetingState == .recording {
            // Reassure the user that browsing history did not stop the meeting.
            HStack(spacing: 5) {
                Circle().fill(Color.red).frame(width: 7, height: 7)
                Text("Recording \(meetingState.elapsedTime)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Back to Live") { history.showLive() }
                .font(.caption)
        }
    }

    private func audioLevelIndicator(label: String, level: Float, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color.opacity(Double(max(level, 0.2))))
                .frame(width: 8, height: 8)

            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()

            Image(systemName: SFSymbols.menuBarProcessing)
                .font(.system(size: 40))
                .foregroundStyle(.tertiary)

            if isArchived {
                Text("Nothing to show")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("This transcript could not be opened.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if meetingState.meetingState == .recording {
                Text("Listening…")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text("Speak or play meeting audio — transcription will appear here")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Meeting Transcription")
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(
                    "Press Start to capture your microphone and system audio.\nSpeakers are separated automatically."
                )
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
            }

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Speaker roster

    /// Renaming lives here, on the roster, rather than in a per-row context menu:
    /// the rows auto-scroll during a live meeting, making a 56pt badge a moving
    /// target, and a speaker name is a property of the roster, not of one line.
    @ViewBuilder
    private var speakerRoster: some View {
        let indices = transcript.presentSpeakerIndices
        if !indices.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(indices, id: \.self) { index in
                        speakerChip(index)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    @ViewBuilder
    private func speakerChip(_ index: Int) -> some View {
        let speaker = MeetingSpeaker.others(speakerIndex: index)
        let color = speakerColor(speaker)

        if editingSpeakerIndex == index {
            TextField("Name", text: $editingName)
                .textFieldStyle(.roundedBorder)
                .font(.caption)
                .frame(width: 110)
                .focused($speakerFieldFocused)
                .onAppear { speakerFieldFocused = true }
                .onSubmit { commitRename(index) }
                .onExitCommand { cancelRename() }
                .accessibilityLabel("Name for \(transcript.displayName(for: speaker))")
        } else {
            Button {
                beginRename(index)
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(color).frame(width: 6, height: 6)
                    Text(transcript.displayName(for: speaker))
                        .font(.caption.weight(.medium))
                    Image(systemName: SFSymbols.rename)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(color.opacity(0.12))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Rename this speaker")
            .accessibilityLabel("Rename \(transcript.displayName(for: speaker))")
        }
    }

    private func beginRename(_ index: Int) {
        // Pre-fill with the assigned name only; the generic "Speaker N"
        // placeholder would otherwise have to be deleted before typing.
        editingName = transcript.speakerNames[String(index)] ?? ""
        editingSpeakerIndex = index
    }

    private func cancelRename() {
        editingSpeakerIndex = nil
        editingName = ""
    }

    private func commitRename(_ index: Int) {
        let name = editingName
        cancelRename()

        if isArchived {
            Task { await history.renameSpeaker(index: index, to: name) }
        } else {
            meetingState.renameSpeaker(index: index, to: name)
        }
    }

    // MARK: - Transcript List

    private var transcriptList: some View {
        VStack(spacing: 0) {
            speakerRoster

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(transcript.entries) { entry in
                            transcriptRow(entry)
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .onChange(of: transcript.entries.count) { _, _ in
                    // Only follow the live session. Auto-scrolling an archived
                    // transcript would yank the reader to the bottom whenever
                    // the selection changed.
                    guard !isArchived, let lastEntry = transcript.entries.last else { return }
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
                .onChange(of: history.selection) { _, _ in
                    // Show a newly opened archive from its beginning.
                    if let first = transcript.entries.first {
                        proxy.scrollTo(first.id, anchor: .top)
                    }
                }
            }
        }
    }

    private func transcriptRow(_ entry: MeetingTranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(MeetingTranscript.formatTime(entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)

            // Resolved through the transcript so a rename relabels every entry.
            Text(transcript.displayName(for: entry.speaker))
                .font(.caption.weight(.semibold))
                .foregroundStyle(speakerColor(entry.speaker))
                .frame(width: 70, alignment: .leading)
                .lineLimit(1)

            Text(entry.text)
                .font(.callout)
                .foregroundStyle(theme.primaryTextColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    /// Color for a speaker badge. "You" is blue; each diarized remote speaker
    /// gets a distinct color, cycling for indices beyond the palette. Unknown
    /// (cold-start / diarization off) remote speech is gray.
    private func speakerColor(_ speaker: MeetingSpeaker) -> Color {
        switch speaker {
        case .you:
            return .blue
        case .others(.none):
            return .gray
        case .others(.some(let index)):
            let palette: [Color] = [.green, .orange, .purple, .pink]
            return palette[index % palette.count]
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            Text("\(transcript.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            Button {
                copyTranscript()
            } label: {
                Label("Copy", systemImage: SFSymbols.copy)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .disabled(transcript.entries.isEmpty)

            Button {
                isExporting = true
            } label: {
                Label("Export", systemImage: SFSymbols.download)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .disabled(transcript.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func copyTranscript() {
        let text = transcript.asPlainText()
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
