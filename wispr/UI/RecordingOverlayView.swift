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
    @State private var audioLevels: [Float] = Array(repeating: 0, count: 20)

    /// Task consuming the audio level stream.
    @State private var levelTask: Task<Void, Never>?

    /// Whether the recording glow pulse is in its "on" phase.
    @State private var isGlowActive: Bool = false

    /// Scaled overlay width for Dynamic Type support (Req 17.7).
    @ScaledMetric(relativeTo: .body) private var overlayWidth: CGFloat = 240

    /// Scaled overlay height for Dynamic Type support (Req 17.7).
    @ScaledMetric(relativeTo: .body) private var overlayHeight: CGFloat = 72

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
        .onAppear {
            handleStateChange(stateManager.appState)
        }
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

    /// Recording state: microphone icon + animated audio level bars.
    private var recordingContent: some View {
        HStack(spacing: 10) {
            Image(systemName: SFSymbols.recordingMicrophone)
                .font(.title)
                .foregroundStyle(theme.accentColor)
                .symbolEffect(.pulse, isActive: !theme.reduceMotion)
                .shadow(
                    color: theme.reduceMotion
                        ? .clear
                        : theme.accentColor.opacity(isGlowActive ? 0.6 : 0.0),
                    radius: isGlowActive ? 8 : 0
                )
                .accessibilityHidden(true)

            audioLevelMeter
        }
        .padding(.horizontal, 20)
    }

    /// Processing state: spinner + label.
    private var processingContent: some View {
        HStack(spacing: 12) {
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
                .font(.callout)
                .foregroundStyle(theme.primaryTextColor)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Audio Level Meter

    /// A horizontal VU meter: vertical bars whose height tracks recent audio levels.
    private var audioLevelMeter: some View {
        HStack(spacing: 2) {
            ForEach(0..<audioLevels.count, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(barColor(for: audioLevels[index]))
                    .frame(width: 4, height: barHeight(for: audioLevels[index]))
            }
        }
        .frame(height: 36, alignment: .center)
        .animation(
            theme.reduceMotion ? nil : .interpolatingSpring(stiffness: 280, damping: 14),
            value: audioLevels
        )
        .accessibilityHidden(true)
    }

    /// Maps a 0…1 audio level to a color: green → yellow → red.
    private func barColor(for level: Float) -> Color {
        let clamped = Double(min(max(level, 0), 1))
        if clamped < 0.5 {
            return theme.accentColor.opacity(0.5 + clamped)
        } else if clamped < 0.8 {
            return .yellow.opacity(0.6 + clamped * 0.4)
        } else {
            return .orange.opacity(0.7 + clamped * 0.3)
        }
    }

    /// Maps a 0…1 audio level to a bar height between 4 and 36 points.
    private func barHeight(for level: Float) -> CGFloat {
        let clamped = min(max(CGFloat(level), 0), 1)
        return 4 + clamped * 32
    }

    // MARK: - State Change Handling

    private func handleStateChange(_ state: AppStateType) {
        switch state {
        case .recording:
            startConsumingAudioLevels()
            startGlowAnimation()
        default:
            stopConsumingAudioLevels()
            stopGlowAnimation()
        }
    }

    // MARK: - Audio Level Stream Consumption

    /// Starts a task that reads from `StateManager.audioLevelStream`
    /// and shifts new samples into the `audioLevels` ring buffer.
    /// If the stream isn't available yet (recording still starting),
    /// polls briefly until it appears.
    private func startConsumingAudioLevels() {
        stopConsumingAudioLevels()

        levelTask = Task { @MainActor in
            // Wait for the stream to become available (recording may still be starting)
            var stream = stateManager.audioLevelStream
            var retries = 0
            while stream == nil, retries < 20, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                stream = stateManager.audioLevelStream
                retries += 1
            }

            guard let stream, !Task.isCancelled else { return }

            for await level in stream {
                guard !Task.isCancelled else { break }
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
        audioLevels = Array(repeating: 0, count: 20)
    }

    // MARK: - Glow Animation

    /// Starts a repeating glow pulse on the microphone icon using SwiftUI animation.
    /// Uses `withAnimation` with a repeating easeInOut — no Timer or Task loop needed.
    /// Skipped entirely when Reduce Motion is enabled.
    private func startGlowAnimation() {
        guard !theme.reduceMotion else { return }
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
            isGlowActive = true
        }
    }

    /// Stops the glow animation and resets state.
    private func stopGlowAnimation() {
        withAnimation(.easeOut(duration: 0.2)) {
            isGlowActive = false
        }
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

#if DEBUG
private struct RecordingOverlayPreview: View {
    @State private var stateManager: StateManager
    @State private var theme = PreviewMocks.makeTheme()

    let state: AppStateType

    init(state: AppStateType = .recording) {
        self.state = state
        let sm = PreviewMocks.makeStateManager()
        sm.appState = state
        // Provide a fake audio level stream so the preview renders bars
        if state == .recording {
            sm.audioLevelStream = AsyncStream { continuation in
                for level in stride(from: Float(0.1), through: 0.9, by: 0.04) {
                    continuation.yield(level)
                }
                continuation.finish()
            }
        }
        _stateManager = State(initialValue: sm)
    }

    var body: some View {
        RecordingOverlayView()
            .environment(stateManager)
            .environment(theme)
            .frame(width: 280, height: 100)
            .background(.black.opacity(0.3))
    }
}

#Preview("Recording") {
    RecordingOverlayPreview(state: .recording)
}

#Preview("Processing") {
    RecordingOverlayPreview(state: .processing)
}

#Preview("Error") {
    RecordingOverlayPreview(state: .error("Microphone access denied"))
}
#endif
