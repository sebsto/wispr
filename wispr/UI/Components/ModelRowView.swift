//
//  ModelRowView.swift
//  wispr
//
//  Reusable model row and status pill views extracted from ModelManagementView.
//  Used by both ModelManagementView and OnboardingModelSelectionStep.
//

import SwiftUI

// MARK: - StatusPillView

/// A reusable pill-shaped badge for displaying model status at a glance.
struct StatusPillView: View {
    let label: String
    let symbolName: String?
    let foregroundColor: Color
    let backgroundColor: Color

    var body: some View {
        HStack(spacing: 4) {
            if let symbolName {
                Image(systemName: symbolName)
                    .font(.caption2.weight(.semibold))
            }
            Text(label)
                .font(.caption.weight(.medium))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(backgroundColor)
        )
        .overlay(
            Capsule()
                .strokeBorder(foregroundColor.opacity(0.3), lineWidth: 0.5)
        )
    }
}

// MARK: - ModelRowView

/// A single row in the model list showing model info and action controls.
/// Status is displayed as a prominent badge/pill for at-a-glance clarity.
/// The active model uses a highlighted card with a green border.
struct ModelRowView: View {
    let model: ModelInfo
    let theme: UIThemeEngine
    let isActivating: Bool
    let isHighlighted: Bool
    let namespace: Namespace.ID
    let onDownload: () -> Void
    let onSetActive: () async -> Void
    let onDelete: () -> Void

    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 32
    @State private var isHovered = false

    /// Whether this model is the active one.
    private var isActive: Bool {
        if case .active = model.status { return true }
        return false
    }

    /// Whether this model has not been downloaded.
    private var isNotDownloaded: Bool {
        if case .notDownloaded = model.status { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Top row: status icon, model name + info, status badge
            HStack(alignment: .center, spacing: 10) {
                statusIcon

                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayName)
                        .font(.headline)
                        .foregroundStyle(isNotDownloaded
                            ? theme.secondaryTextColor
                            : theme.primaryTextColor)

                    HStack(spacing: 6) {
                        Text(model.sizeDescription)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryTextColor)

                        Text("·")
                            .foregroundStyle(theme.secondaryTextColor)

                        Text(model.qualityDescription)
                            .font(.callout)
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                }

                Spacer()

                statusBadge
            }

            // Bottom row: action buttons aligned trailing
            actionButtons
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.successColor.opacity(0.08))
                    .matchedGeometryEffect(id: "activeHighlight", in: namespace)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 12)
                    .fill(theme.primaryTextColor.opacity(0.04))
            }
        }
        .overlay {
            if isHighlighted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(theme.successColor.opacity(0.5), lineWidth: 1.5)
                    .matchedGeometryEffect(id: "activeHighlightBorder", in: namespace)
            }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    // MARK: - Status Icon

    /// A leading icon that reflects the model's current state.
    private var statusIcon: some View {
        Group {
            switch model.status {
            case .active:
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: iconSize, height: iconSize)
                    .background(theme.successColor.gradient, in: Circle())

            case .downloaded:
                Image(systemName: "arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: iconSize, height: iconSize)
                    .background(theme.accentColor.gradient, in: Circle())

            case .notDownloaded:
                Image(systemName: "icloud.and.arrow.down")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.secondaryTextColor.opacity(0.5))
                    .frame(width: iconSize, height: iconSize)
                    .background(theme.secondaryTextColor.opacity(0.08), in: Circle())

            case .downloading:
                ProgressView()
                    .controlSize(.small)
                    .frame(width: iconSize, height: iconSize)
            }
        }
    }

    // MARK: - Status Badge

    /// A prominent pill-shaped badge showing the model's status.
    /// For `.notDownloaded`, shows the Download button inline instead.
    @ViewBuilder
    private var statusBadge: some View {
        switch model.status {
        case .active:
            StatusPillView(
                label: "Active",
                symbolName: theme.actionSymbol(.checkmark),
                foregroundColor: theme.successColor,
                backgroundColor: theme.successColor.opacity(0.15)
            )

        case .downloaded:
            StatusPillView(
                label: "Downloaded",
                symbolName: "checkmark.circle",
                foregroundColor: theme.accentColor,
                backgroundColor: theme.accentColor.opacity(0.12)
            )

        case .notDownloaded:
            Button {
                onDownload()
            } label: {
                Label("Download", systemImage: theme.actionSymbol(.download))
            }
            .buttonStyle(.bordered)
            .highContrastBorder(cornerRadius: 6)
            .keyboardFocusRing()
            .accessibilityLabel("Download \(model.displayName) model")
            .accessibilityHint("Downloads the \(model.sizeDescription) model")

        case .downloading:
            StatusPillView(
                label: "Downloading…",
                symbolName: nil,
                foregroundColor: theme.accentColor,
                backgroundColor: theme.accentColor.opacity(0.12)
            )
        }
    }

    // MARK: - Action Buttons

    /// Action buttons appropriate for the model's current status.
    @ViewBuilder
    private var actionButtons: some View {
        switch model.status {
        case .notDownloaded, .downloading:
            // Download button is inline in statusBadge; downloading handled by parent
            EmptyView()

        case .downloaded:
            HStack {
                Spacer()
                if isActivating {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Activating…")
                            .font(.callout)
                            .foregroundStyle(theme.secondaryTextColor)
                    }
                    .opacity(isActivating ? 0.7 : 1.0)
                    .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isActivating)
                } else {
                    Button {
                        Task { await onSetActive() }
                    } label: {
                        Label("Activate", systemImage: theme.actionSymbol(.checkmark))
                    }
                    .buttonStyle(.borderedProminent)
                    .highContrastBorder(cornerRadius: 6)
                    .keyboardFocusRing()
                    .accessibilityLabel("Set \(model.displayName) as active model")
                    .accessibilityHint("Switches transcription to use this model")
                }

                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: theme.actionSymbol(.delete))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .highContrastBorder(cornerRadius: 6)
                .keyboardFocusRing()
                .disabled(isActivating)
                .accessibilityLabel("Delete \(model.displayName) model")
                .accessibilityHint("Removes the model from disk")
            }

        case .active:
            HStack {
                Spacer()
                Button(role: .destructive) {
                    onDelete()
                } label: {
                    Label("Delete", systemImage: theme.actionSymbol(.delete))
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .highContrastBorder(cornerRadius: 6)
                .keyboardFocusRing()
                .accessibilityLabel("Delete \(model.displayName) model")
                .accessibilityHint("Removes the active model from disk. A different model will be activated.")
            }
        }
    }

    // MARK: - Accessibility

    private var accessibilityDescription: String {
        var parts = [model.displayName, model.sizeDescription, model.qualityDescription]
        switch model.status {
        case .notDownloaded:
            parts.append("Not downloaded")
        case .downloading(let progress):
            parts.append("Downloading \(Int(progress * 100)) percent")
        case .downloaded:
            parts.append("Downloaded")
        case .active:
            parts.append("Active")
        }
        return parts.joined(separator: ", ")
    }
}

#if DEBUG

/// Wrapper that owns the `@Namespace` required by `ModelRowView` previews.
private struct ModelRowPreviewWrapper: View {
    @Namespace private var namespace
    let theme: UIThemeEngine
    let models: [ModelInfo]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(models) { model in
                    ModelRowView(
                        model: model,
                        theme: theme,
                        isActivating: false,
                        isHighlighted: {
                            if case .active = model.status { return true }
                            return false
                        }(),
                        namespace: namespace,
                        onDownload: {},
                        onSetActive: {},
                        onDelete: {}
                    )
                    Divider()
                }
            }
            .padding()
        }
    }
}

#Preview("Model Management") {
    let theme = PreviewMocks.makeTheme()
    let settingsStore = PreviewMocks.makeSettingsStore()
    let models: [ModelInfo] = [
        ModelInfo(id: ModelInfo.KnownID.tiny, displayName: "Tiny", sizeDescription: "~75 MB",
                  qualityDescription: "Fastest, lower accuracy", estimatedSize: 75 * 1024 * 1024, status: .active),
        ModelInfo(id: ModelInfo.KnownID.base, displayName: "Base", sizeDescription: "~140 MB",
                  qualityDescription: "Fast, moderate accuracy", estimatedSize: 140 * 1024 * 1024, status: .downloaded),
        ModelInfo(id: ModelInfo.KnownID.small, displayName: "Small", sizeDescription: "~460 MB",
                  qualityDescription: "Balanced speed and accuracy", estimatedSize: 460 * 1024 * 1024, status: .notDownloaded),
        ModelInfo(id: ModelInfo.KnownID.largeV3, displayName: "Large v3", sizeDescription: "~3 GB",
                  qualityDescription: "Slowest, highest accuracy", estimatedSize: 3072 * 1024 * 1024, status: .notDownloaded),
    ]
    ModelRowPreviewWrapper(theme: theme, models: models)
        .environment(settingsStore)
        .environment(theme)
}

#Preview("Model Management (Dark Mode)") {
    let theme = PreviewMocks.makeTheme()
    let settingsStore = PreviewMocks.makeSettingsStore()
    let models: [ModelInfo] = [
        ModelInfo(id: ModelInfo.KnownID.tiny, displayName: "Tiny", sizeDescription: "~75 MB",
                  qualityDescription: "Fastest, lower accuracy", estimatedSize: 75 * 1024 * 1024, status: .active),
        ModelInfo(id: ModelInfo.KnownID.base, displayName: "Base", sizeDescription: "~140 MB",
                  qualityDescription: "Fast, moderate accuracy", estimatedSize: 140 * 1024 * 1024, status: .downloaded),
        ModelInfo(id: ModelInfo.KnownID.small, displayName: "Small", sizeDescription: "~460 MB",
                  qualityDescription: "Balanced speed and accuracy", estimatedSize: 460 * 1024 * 1024, status: .notDownloaded),
        ModelInfo(id: ModelInfo.KnownID.largeV3, displayName: "Large v3", sizeDescription: "~3 GB",
                  qualityDescription: "Slowest, highest accuracy", estimatedSize: 3072 * 1024 * 1024, status: .notDownloaded),
    ]
    ModelRowPreviewWrapper(theme: theme, models: models)
        .environment(settingsStore)
        .environment(theme)
        .preferredColorScheme(.dark)
}

#endif
