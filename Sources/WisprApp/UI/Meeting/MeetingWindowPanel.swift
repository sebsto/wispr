//
//  MeetingWindowPanel.swift
//  wispr
//
//  Floating NSPanel that hosts the MeetingTranscriptView.
//  Similar to RecordingOverlayPanel but larger and resizable.
//

import AppKit
import SwiftUI

/// A floating `NSPanel` that hosts the meeting transcription UI.
///
/// Unlike the compact RecordingOverlayPanel, this is a resizable window
/// with title bar, close button, and full transcript view.
@MainActor
final class MeetingWindowPanel: NSObject, NSWindowDelegate {

    // MARK: - Properties

    private var panel: NSPanel?
    /// The full frame width before history was opened, retained so a close can
    /// restore precisely the compact width rather than a hard-coded size.
    private var compactFrameWidth: CGFloat?
    /// The full frame width produced by the most recent programmatic expansion.
    /// If the user resizes while history is open, the close path leaves that user
    /// chosen width untouched instead of unexpectedly shrinking the panel.
    private var expandedFrameWidth: CGFloat?

    private let meetingStateManager: MeetingStateManager
    private let settingsStore: SettingsStore
    private let themeEngine: UIThemeEngine
    private let historyStore: MeetingHistoryStore

    /// Whether the panel is currently visible.
    private(set) var isVisible = false

    /// Whether the panel has been shown at least once this launch. Guards the
    /// default corner placement so reopening never overrides a position the user
    /// chose themselves.
    private var hasBeenShown = false

    /// Key under which AppKit autosaves this window's frame.
    private static let frameAutosaveName = "MeetingTranscriptionWindow"
    private static let widthTolerance: CGFloat = 0.5

    /// Whether AppKit has a stored frame for this window.
    ///
    /// Assigning `setFrameAutosaveName` restores a saved frame over the
    /// `contentRect` passed at construction, so the default corner placement must
    /// only be applied when nothing was stored. Checked explicitly rather than
    /// inferred from the frame, since a freshly-created window's origin is not
    /// guaranteed to be exactly `.zero`.
    private static var hasAutosavedFrame: Bool {
        UserDefaults.standard.object(forKey: "NSWindow Frame \(frameAutosaveName)") != nil
    }

    // MARK: - Initialization

    init(
        meetingStateManager: MeetingStateManager,
        settingsStore: SettingsStore,
        themeEngine: UIThemeEngine,
        historyStore: MeetingHistoryStore
    ) {
        self.meetingStateManager = meetingStateManager
        self.settingsStore = settingsStore
        self.themeEngine = themeEngine
        self.historyStore = historyStore
    }

    // MARK: - Panel Lifecycle

    /// Shows the meeting window, or brings it to the front if already open.
    ///
    /// Being already visible is not a no-op: the panel can be buried behind a
    /// fullscreen application, so a menu click must still raise it. This mirrors
    /// the already-visible handling in `MenuBarController.openSettings()`.
    func show() {
        if panel == nil {
            createPanel()
        }

        guard let panel else { return }

        if isVisible {
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }

        // Place the panel only on first show; afterwards the autosaved frame set
        // in createPanel() restores the user's own position and size.
        if !hasBeenShown {
            positionPanel(panel)
            hasBeenShown = true
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Dismisses the meeting window.
    func dismiss() {
        guard let panel, isVisible else { return }
        panel.orderOut(nil)
        isVisible = false
    }

    // MARK: - Private Helpers

    private func createPanel() {
        let transcriptView = MeetingTranscriptView { [weak self] visible in
            self?.setHistoryVisible(visible)
        }
        .environment(meetingStateManager)
        .environment(settingsStore)
        .environment(themeEngine)
        .environment(historyStore)

        let hostingView = NSHostingView(rootView: transcriptView)

        let panel = NSPanel(
            // Compact by default; opening history grows the panel by the sidebar
            // width and closing it returns to this exact width.
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
            styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )

        panel.title = "Meeting Transcription"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = true
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView
        panel.minSize = NSSize(
            width: MeetingTranscriptView.compactMinimumWidth,
            height: MeetingTranscriptView.minimumHeight
        )
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Persist position and size across close/reopen and across launches.
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        self.panel = panel
    }

    /// Adjusts the AppKit window in lockstep with SwiftUI history visibility.
    /// Opening remembers the exact compact frame width and expands by the fixed
    /// sidebar + divider width. Closing restores it only when the user has not
    /// resized the expanded window themselves.
    private func setHistoryVisible(_ visible: Bool) {
        guard let panel else { return }

        if visible {
            let compactWidth = panel.frame.width
            compactFrameWidth = compactWidth
            panel.minSize.width =
                MeetingTranscriptView.compactMinimumWidth
                + MeetingTranscriptView.historyWidthIncrement

            var expandedFrame = panel.frame
            expandedFrame.size.width = compactWidth + MeetingTranscriptView.historyWidthIncrement
            panel.setFrame(expandedFrame, display: true, animate: true)
            expandedFrameWidth = panel.frame.width
            return
        }

        panel.minSize.width = MeetingTranscriptView.compactMinimumWidth
        defer {
            compactFrameWidth = nil
            expandedFrameWidth = nil
        }

        guard
            let compactFrameWidth,
            let expandedFrameWidth,
            abs(panel.frame.width - expandedFrameWidth) <= Self.widthTolerance
        else {
            return
        }

        var compactFrame = panel.frame
        compactFrame.size.width = compactFrameWidth
        panel.setFrame(compactFrame, display: true, animate: true)
    }

    // MARK: - NSWindowDelegate

    /// Called when the user closes the window via the red X button.
    /// Syncs both the panel's flag and the state manager's observable property
    /// so the observation loop can re-trigger on the next menu click.
    func windowWillClose(_ notification: Notification) {
        isVisible = false
        meetingStateManager.isWindowVisible = false
    }

    // MARK: - Positioning

    /// Places the panel in the bottom-right corner, for the first launch only.
    private func positionPanel(_ panel: NSPanel) {
        // A restored autosaved frame already carries the user's own placement.
        guard !Self.hasAutosavedFrame, let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        // Position in the bottom-right corner with some padding
        let x = screenFrame.maxX - panelSize.width - 20
        let y = screenFrame.minY + 20
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
