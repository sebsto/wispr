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

    var body: some View {
        VStack(spacing: 0) {
            // Header with controls
            headerBar

            Divider()

            // Transcript area
            if meetingState.transcript.entries.isEmpty {
                emptyState
            } else {
                transcriptList
            }

            Divider()

            // Footer with export actions
            footerBar
        }
        .frame(minWidth: 360, minHeight: 400)
        .fileExporter(
            isPresented: $isExporting,
            document: TranscriptDocument(text: meetingState.transcript.asPlainText()),
            contentType: .plainText,
            defaultFilename: "meeting-transcript"
        ) { result in
            if case .failure(let error) = result {
                Log.stateManager.error("Export failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
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

            // Audio level indicators
            if meetingState.meetingState == .recording {
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
                    ForEach(meetingState.transcript.entries) { entry in
                        transcriptRow(entry)
                            .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            }
            .onChange(of: meetingState.transcript.entries.count) { _, _ in
                // Auto-scroll to latest entry
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
            Text(entry.speaker.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.speaker == .you ? .blue : .green)
                .frame(width: 48, alignment: .leading)

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

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 12) {
            // Entry count
            Text("\(meetingState.transcript.entries.count) entries")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer()

            // Copy button
            Button {
                meetingState.copyTranscript()
            } label: {
                Label("Copy", systemImage: SFSymbols.copy)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .disabled(meetingState.transcript.entries.isEmpty)

            // Export button
            Button {
                isExporting = true
            } label: {
                Label("Export", systemImage: SFSymbols.download)
                    .font(.callout)
            }
            .buttonStyle(.plain)
            .disabled(meetingState.transcript.entries.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}
