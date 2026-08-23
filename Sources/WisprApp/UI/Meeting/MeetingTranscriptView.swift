//
//  MeetingTranscriptView.swift
//  wispr
//
//  Scrolling transcript view with speaker labels and timestamps.
//  Displayed inside the MeetingWindowPanel.
//

import SwiftUI
import UniformTypeIdentifiers
import WisprCore
import os

/// The main content view for the meeting transcription window.
///
/// Shows recording controls at the top, a scrolling transcript in the middle,
/// and export actions at the bottom.
struct MeetingTranscriptView: View {
    @Environment(MeetingStateManager.self) private var meetingState: MeetingStateManager
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    @State private var isExporting = false

    /// Owns the saved-transcript list. Held here rather than injected because
    /// nothing outside this window needs it.
    @State private var history = MeetingHistoryStore()

    /// Whether the history column is shown. Owned locally so the toggle button
    /// keeps a fixed position.
    @State private var showHistory = false

    /// Speaker being renamed in the roster, and the in-flight text.
    @State private var editingSpeaker: MeetingSpeaker?
    @State private var editingSpeakerName = ""

    /// Focuses the rename field as it appears, so a name can be typed straight
    /// away instead of having to click into the visible box first.
    @FocusState private var speakerFieldFocused: Bool

    /// The transcript on screen: the live session, or one loaded from disk.
    ///
    /// Deliberately decoupled from `meetingState.transcript` so that opening an
    /// archived session cannot disturb a recording in progress, and starting a
    /// meeting cannot wipe an archive the user is reading.
    private var displayedTranscript: MeetingTranscript {
        if history.isShowingArchived {
            return history.loadedTranscript ?? MeetingTranscript()
        }
        return meetingState.transcript
    }

    /// Archived sessions have no live controls and no auto-scroll.
    private var isArchived: Bool { history.isShowingArchived }

    var body: some View {
        HStack(spacing: 0) {
            if showHistory {
                MeetingHistorySidebar(history: history)
                Divider()
            }

            VStack(spacing: 0) {
                // Header with controls
                headerBar

                Divider()

                // Speaker names, for a finished session.
                if isArchived && !displayedTranscript.presentSpeakers.isEmpty {
                    speakerRoster
                    Divider()
                }

                // Transcript area
                if displayedTranscript.entries.isEmpty {
                    emptyState
                } else {
                    transcriptList
                }

                Divider()

                // Footer with export actions
                footerBar
            }
            .frame(minWidth: 360, minHeight: 400)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: TranscriptDocument(text: displayedTranscript.asPlainText()),
            contentType: .plainText,
            defaultFilename: exportFilename
        ) { result in
            if case .failure(let error) = result {
                Log.stateManager.error("Export failed: \(error.localizedDescription)")
            }
        }
        // stopMeeting() writes the session to disk; pick it up so it appears in
        // the history list straight away.
        .onChange(of: meetingState.lastSavedTranscriptURL) { _, newValue in
            guard newValue != nil else { return }
            history.refresh()
        }
    }

    /// Archived exports are named after the session, not "meeting-transcript".
    private var exportFilename: String {
        guard isArchived, let summary = history.selectedSummary else {
            return "meeting-transcript"
        }
        return summary.url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            // History toggle. First in the row and never moves, whether the
            // sidebar is open or closed.
            Button {
                showHistory.toggle()
            } label: {
                Image(systemName: "sidebar.left")
                    .font(.body)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        showHistory ? theme.accentColor.opacity(0.15) : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
            .help(showHistory ? "Hide transcript history" : "Show transcript history")
            .accessibilityLabel("Toggle transcript history")

            // Record/Stop button
            Button {
                Task { await meetingState.toggleMeeting() }
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: meetingState.meetingState == .recording
                            ? SFSymbols.stopFill
                            : SFSymbols.recordingMicrophone
                    )
                    .font(.body)

                    Text(meetingState.meetingState == .recording ? "Stop" : "Start Meeting")
                        .font(.callout.weight(.medium))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    meetingState.meetingState == .recording
                        ? Color.red.opacity(0.15)
                        : theme.accentColor.opacity(0.15)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)

            Spacer()

            // Which archived session is open, and the way back to the live one.
            if isArchived {
                if let summary = history.selectedSummary {
                    Text(summary.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Button("Current Session") { history.showLive() }
                    .buttonStyle(.link)
                    .font(.callout)
            }

            // Audio level indicators
            if meetingState.meetingState == .recording && !isArchived {
                HStack(spacing: 8) {
                    audioLevelIndicator(label: "You", level: meetingState.micLevel, color: .blue)
                    audioLevelIndicator(
                        label: "Others", level: meetingState.systemLevel, color: .green)
                }

                // Timer
                Text(meetingState.elapsedTime)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

            if meetingState.meetingState == .recording {
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

    // MARK: - Transcript List

    private var transcriptList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(displayedTranscript.entries) { entry in
                        transcriptRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: meetingState.transcript.entries.count) { _, _ in
                // Auto-scroll to latest entry. Only while the live session is on
                // screen: an archived transcript should stay where the user
                // scrolled it, even if a meeting is recording in the background.
                guard !isArchived else { return }
                if let lastEntry = meetingState.transcript.entries.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private func transcriptRow(_ entry: MeetingTranscriptEntry) -> some View {
        HStack(alignment: .top, spacing: 8) {
            // Timestamp
            Text(formatTime(entry.timestamp))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 50, alignment: .trailing)

            // Speaker badge
            Text(displayedTranscript.displayName(for: entry.speaker))
                .font(.caption.weight(.semibold))
                .foregroundStyle(speakerColor(entry.speaker))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)

            // Text
            Text(entry.text)
                .font(.callout)
                .foregroundStyle(theme.primaryTextColor)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 4)
    }

    private func formatTime(_ date: Date) -> String {
        MeetingTranscript.formatTime(date)
    }

    // MARK: - Speaker Roster

    /// Lets each speaker in a finished session be given a real name.
    ///
    /// Offered only for an archived session: naming is most useful once the
    /// meeting is over (which is when you know who "Speaker 2" was), and an
    /// archived session has a file to write the name back to. The live
    /// transcript has no file until it is saved.
    private var speakerRoster: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Text("Speakers")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                ForEach(displayedTranscript.presentSpeakers, id: \.self) { speaker in
                    if editingSpeaker == speaker {
                        TextField(speaker.displayName, text: $editingSpeakerName)
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                            .frame(width: 120)
                            .focused($speakerFieldFocused)
                            .onAppear { speakerFieldFocused = true }
                            .onSubmit { commitSpeakerRename(speaker) }
                            .onExitCommand { cancelSpeakerRename() }
                    } else {
                        Button {
                            beginSpeakerRename(speaker)
                        } label: {
                            Text(displayedTranscript.displayName(for: speaker))
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(speakerColor(speaker))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(speakerColor(speaker).opacity(0.12))
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .help("Rename this speaker")
                        .contextMenu {
                            Button("Rename…") { beginSpeakerRename(speaker) }
                            if displayedTranscript.speakerNames[speaker.nameKey] != nil {
                                Button("Reset to \(speaker.displayName)") {
                                    history.renameSpeaker(speaker, to: nil)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private func beginSpeakerRename(_ speaker: MeetingSpeaker) {
        editingSpeakerName = displayedTranscript.speakerNames[speaker.nameKey] ?? ""
        editingSpeaker = speaker
    }

    private func commitSpeakerRename(_ speaker: MeetingSpeaker) {
        history.renameSpeaker(speaker, to: editingSpeakerName)
        cancelSpeakerRename()
    }

    private func cancelSpeakerRename() {
        editingSpeaker = nil
        editingSpeakerName = ""
        speakerFieldFocused = false
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
            // Entry count
            Text("\(displayedTranscript.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            // Copy button
            Button {
                meetingState.copy(displayedTranscript)
            } label: {
                Label("Copy", systemImage: SFSymbols.copy)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .disabled(displayedTranscript.entries.isEmpty)

            // Export button
            Button {
                isExporting = true
            } label: {
                Label("Export", systemImage: SFSymbols.download)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .disabled(displayedTranscript.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
