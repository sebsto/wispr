//
//  ModelDownloadProgressView.swift
//  wispr
//
//  Self-contained download progress view that owns its own download state.
//  Used by both ModelManagementView and OnboardingModelSelectionStep.
//  Displays idle state with download button, real-time progress with bytes,
//  error state with retry, and completion confirmation.
//

import SwiftUI

/// Self-contained view that manages a model download lifecycle:
/// idle → downloading (progress) → complete or error (with retry).
struct ModelDownloadProgressView: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    /// The WhisperService actor used for downloading.
    private let whisperService: WhisperService

    /// The model to download.
    private let model: WhisperModelInfo

    /// Whether the download should start automatically when the view appears.
    private let autoStart: Bool

    /// Called when the download completes successfully, passing the model ID.
    private let onComplete: ((String) -> Void)?

    /// Called when the user cancels the download.
    private let onCancel: (() -> Void)?

    // MARK: - Internal Download State

    @State private var progress: Double = 0
    @State private var downloadedBytes: Int64 = 0
    @State private var totalBytes: Int64 = 0
    @State private var error: String?
    @State private var isComplete: Bool = false
    @State private var isDownloading: Bool = false
    @State private var isLoadingModel: Bool = false
    @State private var isWarmingUp: Bool = false
    @State private var lastProgressUpdate: Date = .now

    // MARK: - Init

    init(
        whisperService: WhisperService,
        model: WhisperModelInfo,
        autoStart: Bool = false,
        onComplete: ((String) -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.whisperService = whisperService
        self.model = model
        self.autoStart = autoStart
        self.onComplete = onComplete
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 14) {
            if isComplete {
                completionView
                    .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .center)))
            } else if let error {
                errorView(error: error)
            } else if isWarmingUp {
                warmingUpView
            } else if isLoadingModel {
                loadingModelView
            } else if isDownloading {
                progressView
            } else {
                idleView
            }
        }
        .animation(.easeInOut(duration: 0.35), value: isComplete)
        .accessibilityElement(children: .contain)
        .task {
            if autoStart && !isDownloading && !isComplete && error == nil {
                startDownload()
            }
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
                Button("Cancel", role: .cancel) {
                    cancelDownload()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("Cancel download")
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

            Text("Loading model into memory. This may take a moment for larger models.")
                .font(.callout)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preparing \(model.displayName). Loading model into memory.")
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
                self.error = nil
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
            Image(systemName: "checkmark")
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

    private func startDownload() {
        isDownloading = true
        isLoadingModel = false
        isWarmingUp = false
        progress = 0
        downloadedBytes = 0
        totalBytes = 0
        error = nil
        isComplete = false
        lastProgressUpdate = .now

        Task {
            do {
                let stream = await whisperService.downloadModel(model)
                for try await downloadProgress in stream {
                    switch downloadProgress.phase {
                    case .downloading:
                        if downloadProgress.fractionCompleted != progress {
                            lastProgressUpdate = .now
                        }
                        progress = downloadProgress.fractionCompleted
                        downloadedBytes = downloadProgress.bytesDownloaded
                        totalBytes = downloadProgress.totalBytes
                    case .loadingModel:
                        isDownloading = false
                        isLoadingModel = true
                        isWarmingUp = false
                    case .warmingUp:
                        isDownloading = false
                        isLoadingModel = false
                        isWarmingUp = true
                    }
                }
                isLoadingModel = false
                isWarmingUp = false
                isComplete = true
                isDownloading = false
                onComplete?(model.id)
            } catch {
                self.error = error.localizedDescription
                isDownloading = false
                isLoadingModel = false
                isWarmingUp = false
            }
        }
    }

    private func cancelDownload() {
        isDownloading = false
        isLoadingModel = false
        isWarmingUp = false
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
        whisperService: WhisperService,
        model: WhisperModelInfo,
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
        _error = State(initialValue: previewError)
        _isComplete = State(initialValue: previewIsComplete)
        _isDownloading = State(initialValue: previewIsDownloading)
        _isLoadingModel = State(initialValue: previewIsLoadingModel)
        _isWarmingUp = State(initialValue: previewIsWarmingUp)
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
        let sampleModel = PreviewMocks.sampleModels[2] // "Small", .notDownloaded
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

