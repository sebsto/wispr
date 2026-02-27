//
//  wisprApp.swift
//  wispr
//
//  Main entry point for the Wisp voice dictation application.
//  Initializes all services, sets menu bar-only mode, and shows
//  onboarding on first launch.
//  Requirements: 5.6, 13.1, 13.12
//

import SwiftUI

/// Main application entry point for Wisp.
///
/// Sets `NSApplication.ActivationPolicy.accessory` so the app lives
/// entirely in the menu bar with no Dock icon (Req 5.6).
/// On first launch, presents the `OnboardingFlow` wizard (Req 13.1).
/// On subsequent launches, the menu bar is the only visible UI.
@main
struct WispApp: App {

    // MARK: - App Delegate

    /// Adaptor that bootstraps services and manages the menu bar lifecycle.
    @NSApplicationDelegateAdaptor(WispAppDelegate.self) private var appDelegate

    // MARK: - Body

    var body: some Scene {
        // Onboarding window — shown only on first launch (Req 13.1)
        Window("Wisp Setup", id: "onboarding") {
            if let stateManager = appDelegate.stateManager {
                OnboardingFlow(whisperService: appDelegate.whisperService, onDismiss: {
                    appDelegate.completeOnboarding()
                })
                .environment(appDelegate.permissionManager)
                .environment(appDelegate.settingsStore)
                .environment(appDelegate.themeEngine)
                .environment(stateManager)
                .frame(minWidth: 600, minHeight: 500)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Settings window — opened from menu bar
        Window("Wisp Settings", id: "settings") {
            if let stateManager = appDelegate.stateManager {
                SettingsView(
                    audioEngine: appDelegate.audioEngine,
                    whisperService: appDelegate.whisperService
                )
                .environment(appDelegate.settingsStore)
                .environment(appDelegate.themeEngine)
                .environment(stateManager)
                .environment(appDelegate.permissionManager)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Model Management window — opened from menu bar
        Window("Model Management", id: "model-management") {
            if let stateManager = appDelegate.stateManager {
                ModelManagementView(whisperService: appDelegate.whisperService)
                    .environment(appDelegate.settingsStore)
                    .environment(appDelegate.themeEngine)
                    .environment(stateManager)
            }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    // MARK: - Initialization

    init() {
        // Requirement 5.6: Menu bar-only app — no Dock icon
        NSApplication.shared.setActivationPolicy(.accessory)
    }
}

// MARK: - App Delegate

/// Application delegate that bootstraps all services on launch.
///
/// Using `NSApplicationDelegate` ensures services are initialized
/// before any SwiftUI scene body is evaluated, and provides a
/// clean hook for the `applicationDidFinishLaunching` lifecycle event.
@MainActor
final class WispAppDelegate: NSObject, NSApplicationDelegate {

    // MARK: - Services

    /// Persistent settings store — created first since other services read from it.
    let settingsStore = SettingsStore()

    /// Permission manager for microphone and accessibility checks.
    let permissionManager = PermissionManager()

    /// Audio capture engine (actor).
    let audioEngine = AudioEngine()

    /// On-device transcription service (actor).
    let whisperService = WhisperService()

    /// Text insertion via Accessibility API / clipboard fallback.
    let textInsertionService = TextInsertionService()

    /// Global hotkey registration (Carbon Events).
    let hotkeyMonitor = HotkeyMonitor()

    /// Shared UI theme engine for appearance and accessibility adaptations.
    let themeEngine = UIThemeEngine.shared

    /// Central state coordinator — depends on all services above.
    private(set) var stateManager: StateManager?

    /// Menu bar status item controller.
    private var menuBarController: MenuBarController?

    /// Recording overlay floating panel.
    private var overlayPanel: RecordingOverlayPanel?

    /// Task observing StateManager.appState to drive overlay visibility.
    private var overlayObservationTask: Task<Void, Never>?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        bootstrap()
    }

    // MARK: - Bootstrap

    /// Initializes all services and wires them together.
    ///
    /// Creates the `StateManager` with all dependencies, sets up the menu bar,
    /// registers the hotkey, and starts monitoring tasks.
    private func bootstrap() {
        // Build the StateManager with all injected dependencies
        let sm = StateManager(
            audioEngine: audioEngine,
            whisperService: whisperService,
            textInsertionService: textInsertionService,
            hotkeyMonitor: hotkeyMonitor,
            permissionManager: permissionManager,
            settingsStore: settingsStore
        )
        stateManager = sm

        // Create menu bar controller (Req 5.1)
        menuBarController = MenuBarController(
            stateManager: sm,
            settingsStore: settingsStore,
            themeEngine: themeEngine
        )

        // Create recording overlay panel
        overlayPanel = RecordingOverlayPanel(
            stateManager: sm,
            themeEngine: themeEngine
        )

        // Register the persisted hotkey (Req 1.3)
        do {
            try hotkeyMonitor.register(
                keyCode: settingsStore.hotkeyKeyCode,
                modifiers: settingsStore.hotkeyModifiers
            )
        } catch {
            // Non-fatal — user can reconfigure in settings
        }

        // Start theme engine monitoring for appearance / accessibility changes
        themeEngine.startMonitoring()

        // Start observing state to drive overlay visibility (Req 9.1, 9.3, 9.4, 9.5)
        startOverlayObservation(stateManager: sm)

        // Start permission monitoring
        Task {
            await permissionManager.startMonitoringPermissionChanges()
        }

        // Requirement 13.1, 13.12: Show onboarding on first launch
        if !settingsStore.onboardingCompleted {
            Task { @MainActor in
                NSApp.activate(ignoringOtherApps: true)
                // Open the onboarding window via the environment
                if let window = NSApp.windows.first(where: {
                    $0.title == "Wisp Setup"
                }) {
                    window.makeKeyAndOrderFront(nil)
                }
            }
        }
    }

    /// Called when the user completes onboarding.
    ///
    /// Persists the onboarding-completed flag (Req 13.12) and
    /// dismisses the onboarding window.
    func completeOnboarding() {
        settingsStore.onboardingCompleted = true
        // Close the onboarding window
        if let window = NSApp.windows.first(where: {
            $0.title == "Wisp Setup"
        }) {
            window.close()
        }
    }

    // MARK: - Overlay State Observation

    /// Observes `StateManager.appState` and shows/dismisses the overlay panel accordingly.
    ///
    /// - Shows the overlay when state transitions to `.recording`
    /// - Keeps it visible during `.processing`
    /// - Dismisses when transitioning to `.idle`
    /// - Shows error state (overlay stays visible until StateManager auto-resets to `.idle`)
    ///
    /// **Validates**: Requirement 9.1 (overlay appears on recording),
    /// 9.3 (processing indicator), 9.4 (auto-dismiss on idle),
    /// 9.5 (error display before dismiss)
    private func startOverlayObservation(stateManager sm: StateManager) {
        overlayObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let currentState = sm.appState

                switch currentState {
                case .recording, .processing, .error:
                    // Show overlay if not already visible
                    if let overlay = self.overlayPanel, !overlay.isVisible {
                        overlay.show()
                    }
                case .idle:
                    // Dismiss overlay if visible
                    if let overlay = self.overlayPanel, overlay.isVisible {
                        overlay.dismiss()
                    }
                }

                // Wait for the next state change using Observation framework
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = sm.appState
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }
}
