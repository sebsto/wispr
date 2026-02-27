//
//  RecordingOverlayView.swift
//  wispr
//
//  SwiftUI view displayed inside the RecordingOverlayPanel.
//  Shows recording indicator, audio level meter, processing spinner, and error messages.
//  Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 14.3, 14.8, 14.9, 14.10, 14.12
//

import SwiftUI

/// The SwiftUI content view hosted inside `RecordingOverlayPanel`.
///
/// Displays different content based on the current `AppStateType`:
/// - `.recording` — pulsing microphone icon + real-time audio level bars
/// - `.processing` — spinning progress indicator
/// - `.error` — error message with warning icon (auto-dismisses after 3s)
///
/// The view consumes `StateManager.audioLevelStream` for real-time audio levels
/// and uses `UIThemeEngine` for Liquid Glass materials, spring animations,
/// and accessibility adaptations (Reduce Motion, Reduce Transparency).
///
/// **Validates**: Requirements 9.1–9.5, 14.3, 14.8, 14.9, 14.10, 14.12
struct RecordingOverlayView: View {
    @Environment(StateManager.self) private var stateManager: StateManager
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// Recent audio level samples for the level meter visualization.
    @State private var audioLevels: [Float] = Array(repeating: 0, count: 12)

    /// Task consuming the audio level stream.
    @State private var levelTask: Task<Void, Never>?

    /// Scaled overlay width for Dynamic Type support (Req 17.7).
    @ScaledMetric(relativeTo: .body) private var overlayWidth: CGFloat = 200

    /// Scaled overlay height for Dynamic Type support (Req 17.7).
    @ScaledMetric(relativeTo: .body) private var overlayHeight: CGFloat = 60

    var body: some View {
        ZStack {
            overlayContent
        }
        .frame(width: overlayWidth, height: overlayHeight)
        .liquidGlassOverlay()
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .highContrastBorder(cornerRadius: 16)
        .shadow(color: .black.opacity(0.15), radius: 8, x: 0, y: 4)
        .motionRespectingAnimation(value: stateManager.appState)
        .onChange(of: stateManager.appState) { _, newState in
            handleStateChange(newState)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabelForState)
        .accessibilityHint("Release the hotkey to stop recording")
        .accessibilityAddTraits(.updatesFrequently)
    }

    // MARK: - Content

    @ViewBuilder
    private var overlayContent: some View {
        switch stateManager.appState {
        case .recording:
            recordingContent
        case .processing:
            processingContent
        case .error(let message):
            errorContent(message: message)
        case .idle:
            EmptyView()
        }
    }

    /// Recording state: microphone icon + audio level bars.
    private var recordingContent: some View {
        HStack(spacing: 10) {
            Image(systemName: SFSymbols.recordingMicrophone)
                .font(.title2)
                .foregroundStyle(theme.accentColor)
                .symbolEffect(.pulse, isActive: !theme.reduceMotion)
                .accessibilityHidden(true)

            audioLevelMeter
        }
        .padding(.horizontal, 16)
    }

    /// Processing state: spinner + label.
    private var processingContent: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)

            Text("Processing…")
                .font(.callout)
                .foregroundStyle(theme.primaryTextColor)
        }
    }

    /// Error state: warning icon + message.
    private func errorContent(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: SFSymbols.overlayError)
                .font(.callout)
                .foregroundStyle(theme.errorColor)
                .accessibilityHidden(true)

            Text(message)
                .font(.caption)
                .foregroundStyle(theme.primaryTextColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 12)
    }

    // MARK: - Audio Level Meter

    /// A row of vertical bars representing recent audio levels.
    private var audioLevelMeter: some View {
        HStack(spacing: 3) {
            ForEach(0..<audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(theme.accentColor.opacity(0.8))
                    .frame(width: 4, height: barHeight(for: audioLevels[index]))
            }
        }
        .frame(height: 28)
        .accessibilityHidden(true)
    }

    /// Maps a 0…1 audio level to a bar height between 4 and 28 points.
    private func barHeight(for level: Float) -> CGFloat {
        let clamped = min(max(CGFloat(level), 0), 1)
        return 4 + clamped * 24
    }

    // MARK: - State Change Handling

    private func handleStateChange(_ state: AppStateType) {
        switch state {
        case .recording:
            startConsumingAudioLevels()
        default:
            stopConsumingAudioLevels()
        }
    }

    // MARK: - Audio Level Stream Consumption

    /// Starts a task that reads from `StateManager.audioLevelStream`
    /// and shifts new samples into the `audioLevels` ring buffer.
    private func startConsumingAudioLevels() {
        stopConsumingAudioLevels()

        guard let stream = stateManager.audioLevelStream else { return }

        levelTask = Task { @MainActor in
            for await level in stream {
                guard !Task.isCancelled else { break }
                // Shift left and append new sample
                if audioLevels.count > 1 {
                    audioLevels.removeFirst()
                }
                audioLevels.append(level)
            }
        }
    }

    /// Cancels the audio level consumption task and resets levels.
    private func stopConsumingAudioLevels() {
        levelTask?.cancel()
        levelTask = nil
        audioLevels = Array(repeating: 0, count: 12)
    }

    // MARK: - Accessibility

    private var accessibilityLabelForState: String {
        switch stateManager.appState {
        case .recording:
            "Recording in progress"
        case .processing:
            "Processing speech"
        case .error(let message):
            "Error: \(message)"
        case .idle:
            "Recording overlay"
        }
    }
}
