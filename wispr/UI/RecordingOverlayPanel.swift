//
//  RecordingOverlayPanel.swift
//  wispr
//
//  Borderless floating NSPanel that hosts the RecordingOverlayView.
//  Requirements: 9.1, 9.4, 14.8, 14.10
//

import AppKit
import SwiftUI

/// A borderless, floating `NSPanel` that hosts the `RecordingOverlayView`.
///
/// The panel is configured as a non-activating floating window so it appears
/// above all other windows without stealing focus from the frontmost application.
/// Show/dismiss uses spring animations (≤300ms) that respect Reduce Motion.
///
/// ## Why NSPanel + NSAnimationContext? (Modernization blocker)
/// SwiftUI `Window` scenes always activate the app when shown via `openWindow`, stealing
/// focus from whatever the user is dictating into. macOS 26 added `.windowLevel(.floating)`
/// and `.allowsWindowActivationEvents(false)`, but the latter only prevents gesture-based
/// activation — the window itself still activates on appearance. There is also no SwiftUI
/// equivalent for `hidesOnDeactivate = false`, `.canJoinAllSpaces`, or `orderFrontRegardless()`.
/// `NSAnimationContext` is tied to `NSPanel` (animates `alphaValue`); if the panel migrates,
/// the animations migrate with it. Unblocked if Apple ships a non-activating SwiftUI window
/// primitive (e.g. `WindowActivationPolicy` or `WindowStyle.nonActivating`). Monitor WWDC 2026.
///
/// **Validates**: Requirement 9.1 (overlay appears on recording),
/// 9.4 (auto-dismiss on idle), 14.8 (spring animations ≤300ms),
/// 14.10 (compact borderless floating window)
@MainActor
final class RecordingOverlayPanel {

    // MARK: - Properties

    private var panel: NSPanel?
    private let stateManager: StateManager
    private let themeEngine: UIThemeEngine

    /// Whether the panel is currently visible.
    private(set) var isVisible = false

    // MARK: - Initialization

    /// Creates a new overlay panel controller.
    ///
    /// - Parameters:
    ///   - stateManager: The state manager driving overlay visibility.
    ///   - themeEngine: The theme engine for accessibility adaptations.
    init(stateManager: StateManager, themeEngine: UIThemeEngine) {
        self.stateManager = stateManager
        self.themeEngine = themeEngine
    }

    // MARK: - Panel Lifecycle

    /// Shows the recording overlay panel with a spring animation.
    ///
    /// The panel is positioned at the bottom-center of the main screen.
    /// Uses `NSPanel` with `.nonactivatingPanel` style so it does not
    /// steal focus from the user's active application.
    func show() {
        if panel == nil {
            createPanel()
        }

        guard let panel, !isVisible else { return }

        positionPanel(panel)

        // Start transparent for fade-in
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        isVisible = true

        // Animate in — respect Reduce Motion
        let duration = themeEngine.reduceMotion ? 0.0 : 0.25
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1.0
        }
    }

    /// Dismisses the recording overlay panel with a spring animation.
    func dismiss() {
        guard let panel, isVisible else { return }

        let duration = themeEngine.reduceMotion ? 0.0 : 0.2
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0.0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.panel?.orderOut(nil)
                self.isVisible = false
            }
        })
    }

    // MARK: - Private Helpers

    private func createPanel() {
        let overlayView = RecordingOverlayView()
            .environment(stateManager)
            .environment(themeEngine)

        let hostingView = NSHostingView(rootView: overlayView)
        hostingView.setFrameSize(NSSize(width: 260, height: 92))

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 92),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hostingView

        self.panel = panel
    }

    private func positionPanel(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let panelSize = panel.frame.size

        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.minY + 80 // 80pt above the bottom of the visible area
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}
