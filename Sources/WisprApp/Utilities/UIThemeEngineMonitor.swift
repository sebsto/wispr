//
//  UIThemeEngineMonitor.swift
//  wispr
//
//  AppKit-dependent monitoring logic for UIThemeEngine. Observes system
//  appearance (dark/light mode) and accessibility setting changes, then
//  pushes updates into the AppKit-free UIThemeEngine observable.
//
//  This is the only file that imports AppKit on behalf of UIThemeEngine.
//

import AppKit
import Observation

/// Monitors system appearance and accessibility changes, updating
/// `UIThemeEngine.shared` whenever a change is detected.
///
/// Extracted from `UIThemeEngine.swift` to keep the main theme file
/// free of AppKit imports.
@MainActor
final class UIThemeEngineMonitor {

    private var appearanceTask: Task<Void, Never>?
    private var accessibilityTask: Task<Void, Never>?

    private let engine: UIThemeEngine

    init(engine: UIThemeEngine = .shared) {
        self.engine = engine
    }

    // MARK: - Public API

    /// Reads current values and begins observing system changes.
    /// Call once from `applicationDidFinishLaunching` or a `.task` modifier.
    func start() {
        refreshAppearance()
        refreshAccessibilitySettings()
        startMonitoring()
    }

    /// Stops observation and cancels monitoring tasks.
    func stop() {
        appearanceTask?.cancel()
        appearanceTask = nil
        accessibilityTask?.cancel()
        accessibilityTask = nil
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard appearanceTask == nil else { return }

        // Guard against NSApp being nil (e.g. in swift test without a running NSApplication).
        guard let app = NSApp else { return }

        // Observe dark/light mode changes via KVO on NSApp.effectiveAppearance
        appearanceTask = Task { [weak self] in
            let stream = AsyncStream<Void> { continuation in
                let observation = app.observe(\.effectiveAppearance) { _, _ in
                    continuation.yield()
                }
                continuation.onTermination = { _ in
                    _ = observation // prevent the observation from being deallocated
                }
            }
            for await _ in stream {
                guard let self else { return }
                self.refreshAppearance()
            }
        }

        // Observe accessibility setting changes via system notification
        accessibilityTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
            for await _ in notifications {
                guard let self else { return }
                self.refreshAccessibilitySettings()
            }
        }
    }

    // MARK: - Refresh

    /// Reads the current system appearance (light/dark mode).
    private func refreshAppearance() {
        guard let app = NSApp else { return }
        let appearance = app.effectiveAppearance
        engine.isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Reads the current accessibility settings from NSWorkspace.
    private func refreshAccessibilitySettings() {
        let workspace = NSWorkspace.shared
        engine.reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        engine.reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        engine.increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }
}
