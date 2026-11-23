//
//  ModelDownloadProgressView.swift
//  wispr
//
//  Self-contained download progress view that owns its own download state.
//  Used by both ModelManagementView and OnboardingModelSelectionStep.
//  Displays idle state with download button, real-time progress with bytes,
//  error state with retry, and completion confirmation.
//

import WisprCore
import SwiftUI

/// Manages the full download lifecycle: initiation, progress, error/retry, and completion display.
/// Parent views decide which model to download and handle app-level side effects
/// (setting active model, navigation) via `onComplete` and `onCancel`.
struct ModelDownloadProgressView: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// The WhisperService actor used for downloading.
    private let whisperService: any TranscriptionEngine

    /// The model to download.
    private let model: ModelInfo

    /// Whether the download should start automatically when the view appears.
    private let autoStart: Bool

    /// Called when the download completes successfully, passing the model ID.
    private let onComplete: ((String) -> Void)?

    /// Called when the user cancels the download.
    private let onCancel: (() -> Void)?

    // MARK: - Internal Download State

    /// The step of the download lifecycle the view is showing.
    enum Phase: Equatable {
        case idle
        case downloading
        case loadingModel
        case warmingUp
        case failed(String)
        case complete
    }

    @State private var phase: Phase = .idle
    @State private var progress: Double = 0
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var lastProgressUpdate: Date = .now

    /// Identifies the current download attempt. The download runs inside
    /// `.task(id:)`, so changing this (Retry, Cancel) or removing the view
    /// cancels the running download. `nil` means no download is wanted.
    @State private var downloadAttempt: Int?

    // MARK: - Init

    init(
        whisperService: any TranscriptionEngine,
        model: ModelInfo,
        autoStart: Bool = false,
        onComplete: ((String) -> Void)? = nil,
        onCancel: (() -> Void)?
    ) {
        self.whisperService = whisperService
        self.model = model
        self.autoStart = autoStart
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 14) {
            switch phase {
            case .complete:
                completionView
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            case .failed(let error):
                errorView(error: error)
            case .warmingUp:
                warmingUpView
            case .loadingModel:
                loadingModelView
            case .downloading:
                progressView
            case .idle:
                idleView
            }
        }
        .animation(.easeInOut(duration: 0.35), value: phase == .complete)
        .accessibilityElement(children: .contain)
        .task {
            if autoStart && phase == .idle {
                startDownload()
            }
        }
        .task(id: downloadAttempt) {
            guard downloadAttempt != nil else { return }
            await runDownload()
        }
    }

    // MARK: - Idle (Download Button)

    private var idleView: some View {
        VStack(spacing: 10) {
            Text(model.displayName)
                .font(.headline)
                .foregroundStyle(theme.primaryTextColor)

            Button {
                startDownload()
            } label: {
                Label("Download", systemImage: SFSymbols.download)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Download \(model.displayName)")
            .accessibilityHint("Downloads the model to your Mac")
        }
    }

    // MARK: - Progress

    private var progressView: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Downloading \(model.displayName)…")
                    .font(.headline)
                    .foregroundStyle(theme.primaryTextColor)
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.headline)
                    .monospacedDigit()
                    .foregroundStyle(theme.accentColor)
            }

            GradientProgressBar(progress: progress, accentColor: theme.accentColor)
                .animation(.easeInOut(duration: 0.3), value: progress)
                .accessibilityLabel("Download progress")
                .accessibilityValue("\(Int(progress * 100)) percent")

            HStack {
                Text("\(formattedBytes(downloadedBytes)) of \(formattedBytes(totalBytes))")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryTextColor)
                Spacer()
                if onCancel != nil {
                    Button("Cancel", role: .cancel) {
                        cancelDownload()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityLabel("Cancel download")
                }
            }

            // Show a hint when progress hasn't updated for a while
            TimelineView(.periodic(from: .now, by: 2)) { context in
                if context.date.timeIntervalSince(lastProgressUpdate) > 4, progress > 0, progress < 1 {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Still downloading — large files may take a moment")
                            .font(.caption)
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Loading Model

    private var loadingModelView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Preparing \(model.displayName)…")
                    .font(.headline)
                    .foregroundStyle(theme.primaryTextColor)
            }

            Text("Compiling the model for the Neural Engine. This can take a couple of minutes for larger models.")
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing \(model.displayName). Compiling the model for the Neural Engine. This can take a couple of minutes.")
    }

    // MARK: - Warming Up

    private var warmingUpView: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Warming up \(model.displayName)…")
                    .font(.headline)
                    .foregroundStyle(theme.primaryTextColor)
            }

            Text("Running first inference to optimize performance. This only happens once.")
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Warming up \(model.displayName). Running first inference to optimize performance.")
    }

    // MARK: - Error

    private func errorView(error: String) -> some View {
        VStack(spacing: 10) {
            Label("Download Failed", systemImage: SFSymbols.warning)
                .font(.headline)
                .foregroundStyle(theme.errorColor)

            Text(error)
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)

            Button {
                startDownload()
            } label: {
                Label("Retry", systemImage: SFSymbols.retry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .accessibilityLabel("Retry download")
            .accessibilityHint("Attempts to download the model again")
        }
    }

    // MARK: - Completion

    private var completionView: some View {
        HStack(spacing: 10) {
            Image(systemName: SFSymbols.checkmarkPlain)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(theme.successColor.gradient, in: Circle())
            Text("\(model.displayName) downloaded successfully")
                .font(.headline)
                .foregroundStyle(theme.successColor)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.displayName) downloaded successfully")
    }

    // MARK: - Download Logic

    /// Resets progress and starts a new download attempt.
    private func startDownload() {
        phase = .downloading
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        lastProgressUpdate = .now
        downloadAttempt = (downloadAttempt ?? 0) + 1
    }

    /// Runs one download attempt. Called from `.task(id: downloadAttempt)`, so
    /// it is cancelled when the attempt changes or the view goes away.
    private func runDownload() async {
        do {
            let stream = await whisperService.downloadModel(model)
            for try await downloadProgress in stream {
                try Task.checkCancellation()
                switch downloadProgress.phase {
                case .downloading:
                    guard downloadProgress.fractionCompleted != progress else { continue }
                    lastProgressUpdate = .now
                    progress = downloadProgress.fractionCompleted
                    downloadedBytes = downloadProgress.bytesDownloaded
                    totalBytes = downloadProgress.totalBytes
                case .loadingModel:
                    phase = .loadingModel
                case .warmingUp:
                    phase = .warmingUp
                }
            }
            try Task.checkCancellation()
            phase = .complete
            onComplete?(model.id)
        } catch is CancellationError {
            // Cancelled by the user or by the view going away; cancelDownload()
            // already reset the visible state when it was the user.
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(error.localizedDescription)
        }
    }

    private func cancelDownload() {
        downloadAttempt = nil
        phase = .idle
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        onCancel?()
    }

    // MARK: - Helpers

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    private func formattedBytes(_ bytes: Int64) -> String {
        Self.byteFormatter.string(fromByteCount: bytes)
    }
}
// MARK: - GradientProgressBar

/// A capsule-shaped progress bar with a gradient fill for richer visual feedback.
private struct GradientProgressBar: View {
    let progress: Double
    let accentColor: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(accentColor.opacity(0.15))

                Capsule()
                    .fill(accentColor.gradient)
                    .frame(width: max(geometry.size.width * progress, geometry.size.height))
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
    }
}

// MARK: - Preview Support

#if DEBUG
extension ModelDownloadProgressView {
    /// Preview-only initializer that accepts explicit state overrides for canvas previews.
    init(
        whisperService: any TranscriptionEngine,
        model: ModelInfo,
        previewProgress: Double,
        previewDownloadedBytes: Int64 = 0,
        previewTotalBytes: Int64 = 0,
        previewError: String? = nil,
        previewIsComplete: Bool = false,
        previewIsDownloading: Bool = false,
        previewIsLoadingModel: Bool = false,
        previewIsWarmingUp: Bool = false
    ) {
        self.whisperService = whisperService
        self.model = model
        self.autoStart = false
        self.onComplete = nil
        self.onCancel = nil
        _progress = State(initialValue: previewProgress)
        _downloadedBytes = State(initialValue: previewDownloadedBytes)
        _totalBytes = State(initialValue: previewTotalBytes)
        let phase: Phase =
            if previewIsComplete { .complete }
            else if let previewError { .failed(previewError) }
            else if previewIsWarmingUp { .warmingUp }
            else if previewIsLoadingModel { .loadingModel }
            else if previewIsDownloading { .downloading }
            else { .idle }
        _phase = State(initialValue: phase)
        _lastProgressUpdate = State(initialValue: .now)
    }
}

private struct DownloadProgressPreview: View {
    @State private var settingsStore = PreviewMocks.makeSettingsStore()
    @State private var theme = PreviewMocks.makeTheme()
    private let whisperService = PreviewMocks.makeWhisperService()

    let variant: Variant

    enum Variant {
        case progress
        case error
        case complete
        case loadingModel
        case warmingUp
    }

    var body: some View {
        let sampleModel = PreviewMocks.sampleModels.first { $0.id == ModelInfo.KnownID.small }!
        Group {
            switch variant {
            case .progress:
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: sampleModel,
                    previewProgress: 0.45,
                    previewDownloadedBytes: 207_000_000,
                    previewTotalBytes: 460_000_000,
                    previewIsDownloading: true
                )
            case .error:
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: sampleModel,
                    previewProgress: 0,
                    previewError: "Network connection was lost. Please check your internet and try again."
                )
            case .complete:
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: sampleModel,
                    previewProgress: 1.0,
                    previewDownloadedBytes: 460_000_000,
                    previewTotalBytes: 460_000_000,
                    previewIsComplete: true
                )
            case .loadingModel:
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: sampleModel,
                    previewProgress: 1.0,
                    previewDownloadedBytes: 460_000_000,
                    previewTotalBytes: 460_000_000,
                    previewIsLoadingModel: true
                )
            case .warmingUp:
                ModelDownloadProgressView(
                    whisperService: whisperService,
                    model: sampleModel,
                    previewProgress: 1.0,
                    previewDownloadedBytes: 460_000_000,
                    previewTotalBytes: 460_000_000,
                    previewIsWarmingUp: true
                )
            }
        }
        .environment(settingsStore)
        .environment(theme)
        .padding()
        .frame(width: 420)
    }
}

#Preview("Download Progress") {
    DownloadProgressPreview(variant: .progress)
}

#Preview("Download Error") {
    DownloadProgressPreview(variant: .error)
}

#Preview("Download Complete") {
    DownloadProgressPreview(variant: .complete)
}

#Preview("Loading Model") {
    DownloadProgressPreview(variant: .loadingModel)
}

#Preview("Warming Up") {
    DownloadProgressPreview(variant: .warmingUp)
}

#Preview("All Download States") {
    ScrollView {
        VStack(spacing: 24) {
            DownloadProgressPreview(variant: .progress)
            Divider()
            DownloadProgressPreview(variant: .complete)
            Divider()
            DownloadProgressPreview(variant: .error)
            Divider()
            DownloadProgressPreview(variant: .loadingModel)
            Divider()
            DownloadProgressPreview(variant: .warmingUp)
        }
        .padding()
    }
    .frame(width: 420, height: 700)
}
#endif

