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
    /// The smallest useful width for the transcript and its one-line controls.
    static let compactMinimumWidth: CGFloat = 370
    /// Stable sidebar width, shared with `MeetingWindowPanel` so opening history
    /// can increase the AppKit window by exactly the same amount.
    static let historySidebarWidth: CGFloat = 210
    static let historyWidthIncrement = historySidebarWidth + 1  // Divider
    /// Smallest usable height, shared with `MeetingWindowPanel` so the window's
    /// floor and the content's declared minimum cannot drift apart.
    static let minimumHeight: CGFloat = 420

    @Environment(MeetingStateManager.self) private var meetingState: MeetingStateManager
    @Environment(MeetingHistoryStore.self) private var history: MeetingHistoryStore
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// Lets the AppKit-owned panel resize when the sidebar changes visibility.
    let onHistoryVisibilityChanged: ((Bool) -> Void)?

    @State private var isExporting = false
    /// Speaker index whose name is being edited, and the in-flight text.
    @State private var editingSpeakerIndex: Int?
    @State private var editingName = ""
    /// Drives keyboard focus into the rename field the moment it appears, so the
    /// user can type immediately instead of having to click the field first.
    @FocusState private var speakerFieldFocused: Bool
    /// History starts closed for a compact meeting window. It remains view state
    /// for the lifetime of the retained panel, rather than resetting on reopen.
    @State private var showHistory = false

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
        HStack(spacing: 0) {
            if showHistory {
                MeetingHistorySidebar()
                    .frame(width: Self.historySidebarWidth)
                Divider()
            }

            // The header needs enough room for the Start button and the capture
            // mode picker to remain on one line. When history is open, the panel
            // grows by exactly its fixed sidebar width rather than squeezing here.
            detailPane
                .frame(minWidth: Self.compactMinimumWidth)
        }
        .frame(
            minWidth: showHistory
                ? Self.compactMinimumWidth + Self.historyWidthIncrement
                : Self.compactMinimumWidth,
            minHeight: Self.minimumHeight
        )
        .onChange(of: showHistory) { _, visible in
            onHistoryVisibilityChanged?(visible)
        }
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
            headerBar

            if let message = history.errorMessage {
                errorBanner(message)
            }

            Divider()

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
            // History toggle, first in the row so it holds one position whether
            // the sidebar is open or closed.
            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(showHistory ? theme.accentColor.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(showHistory ? "Hide transcript history" : "Show transcript history")
            .accessibilityLabel("Toggle transcript history")

            // Start/Stop sits in the header rather than the transcript body, so
            // it stays reachable while an archived session is on screen.
            recordButton

            if isArchived {
                archivedHeaderContent
            } else {
                liveHeaderContent
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Start/Stop control. The label never wraps: when the header is too narrow
    /// for "Start Meeting"/"Stop" beside the icon, it collapses to the icon alone
    /// rather than stacking the text vertically.
    private var recordButton: some View {
        let isRecording = meetingState.meetingState == .recording
        let icon = isRecording ? SFSymbols.stopFill : SFSymbols.recordingMicrophone
        let title = isRecording ? "Stop" : "Start Meeting"
        let tint = isRecording ? Color.red : theme.accentColor

        return Button {
            Task { await meetingState.toggleMeeting() }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.body)
                    Text(title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .fixedSize()
                }
                // Fallback for a narrow header: the icon carries the action.
                Image(systemName: icon).font(.body)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(tint.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(isRecording ? "Stop meeting" : "Start meeting")
        .accessibilityLabel(isRecording ? "Stop meeting" : "Start meeting")
    }

    @ViewBuilder
    private var liveHeaderContent: some View {
        @Bindable var meetingState = meetingState
        let isRecording = meetingState.meetingState == .recording

        // Capture mode. Locked while recording so a transcript never mixes two
        // labelling schemes.
        Picker("Meeting mode", selection: $meetingState.mode) {
            Text("Online").tag(MeetingMode.online)
            Text("In person").tag(MeetingMode.inPerson)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .disabled(isRecording)
        .help(
            "Online captures your mic plus system audio. In person diarizes the mic for up to four people in the room."
        )
        .accessibilityHint(
            "Choose a remote or an in-person meeting recorded on the microphone. Locked while recording."
        )

        Spacer()

        if isRecording {
            // The level indicators are the first thing to go when the header runs
            // out of room: hide them wholesale rather than let their labels wrap.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    if meetingState.mode == .inPerson {
                        // In person the mic carries the whole room; it is the only
                        // meaningful level.
                        audioLevelIndicator(
                            label: "Room", level: meetingState.micLevel, color: .green)
                    } else {
                        audioLevelIndicator(
                            label: "You", level: meetingState.micLevel, color: .blue)
                        audioLevelIndicator(
                            label: "Others", level: meetingState.systemLevel, color: .green)
                    }
                }
                // Fallback: nothing, so the timer keeps its place at narrow widths.
                Color.clear.frame(width: 0, height: 0)
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
                .lineLimit(1)
                .fixedSize()
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
                    meetingState.mode == .inPerson
                        ? "Press Start to record everyone in the room on your microphone.\nUp to four speakers are separated automatically."
                        : "Press Start to capture your microphone and system audio.\nSpeakers are separated automatically."
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
