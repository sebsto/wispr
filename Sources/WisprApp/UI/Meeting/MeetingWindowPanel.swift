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
        let transcriptView = MeetingTranscriptView()
            .environment(meetingStateManager)
            .environment(settingsStore)
            .environment(themeEngine)
            .environment(historyStore)

        let hostingView = NSHostingView(rootView: transcriptView)

        let panel = NSPanel(
            // Wide enough for the history sidebar plus a readable transcript.
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
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
        // Matches the content's declared minimum. The transcript rows spend
        // ~154pt on the timestamp and speaker columns before any text, so a
        // narrower window leaves nothing readable beside the sidebar.
        panel.minSize = NSSize(width: 620, height: 420)
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // Persist position and size across close/reopen and across launches.
        panel.setFrameAutosaveName(Self.frameAutosaveName)

        self.panel = panel
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
