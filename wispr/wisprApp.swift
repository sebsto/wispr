//
//  wisprApp.swift
//  wispr
//
//  Main entry point for the Wispr voice dictation application.
//  Initializes all services, sets menu bar-only mode, and shows
//  onboarding on first launch.
//  Requirements: 5.6, 13.1, 13.12, 13.16
//

import SwiftUI
import os

/// Main application entry point for Wispr.
///
/// Sets `NSApplication.ActivationPolicy.accessory` so the app lives
/// entirely in the menu bar with no Dock icon (Req 5.6).
/// On first launch, presents the `OnboardingFlow` wizard (Req 13.1).
/// On subsequent launches, the menu bar is the only visible UI.
@main
struct WisprApp: App {

    // MARK: - App Delegate

    /// Adaptor that bootstraps services and manages the menu bar lifecycle.
    @NSApplicationDelegateAdaptor(WisprAppDelegate.self) private var appDelegate

    // MARK: - Body

    var body: some Scene {
        // All windows (onboarding, settings, model management) are opened
        // imperatively via NSWindow + NSHostingController from the app delegate
        // and MenuBarController, because SwiftUI Window scenes don't reliably
        // open in accessory (menu-bar-only) apps.
        //
        // The Settings scene provides the standard "Settings…" (⌘,) menu item.
        // Its body is never shown — the delegate intercepts the action via
        // showSettingsWindow: and opens the real settings window instead.
        Settings {
            EmptyView()
        }
    }

    // MARK: - Initialization

    init() {
        guard ProcessInfo.processInfo.environment["CI_TEST_MODE"] == nil else { return }
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
final class WisprAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {

    // MARK: - Services

    /// Persistent settings store — created first since other services read from it.
    let settingsStore = SettingsStore()

    /// Permission manager for microphone and accessibility checks.
    let permissionManager = PermissionManager()

    /// Audio capture engine (actor).
    let audioEngine = AudioEngine()

    /// On-device transcription service (actor).
    /// Composite engine aggregating WhisperKit and Parakeet V3 behind a single interface.
    let whisperService: any TranscriptionEngine = CompositeTranscriptionEngine(engines: [
        WhisperService(),
        ParakeetService()
    ])

    /// Text insertion via Accessibility API / clipboard fallback.
    let textInsertionService = TextInsertionService()

    /// Global hotkey registration (Carbon Events).
    let hotkeyMonitor = HotkeyMonitor()

    /// Shared UI theme engine for appearance and accessibility adaptations.
    let themeEngine = UIThemeEngine.shared

    /// Checks GitHub Releases for a newer app version.
    let updateChecker = UpdateChecker()

    /// Central state coordinator — depends on all services above.
    private(set) var stateManager: StateManager?

    /// Menu bar status item controller.
    private var menuBarController: MenuBarController?

    /// Recording overlay floating panel.
    private var overlayPanel: RecordingOverlayPanel?

    /// Task observing StateManager.appState to drive overlay visibility.
    private var overlayObservationTask: Task<Void, Never>?

    /// Task observing hotkey settings changes to re-register the global hotkey.
    private var hotkeyObservationTask: Task<Void, Never>?

    /// Task monitoring permission changes (microphone, accessibility).
    private var permissionMonitoringTask: Task<Void, Never>?

    /// Task that checks for app updates on launch.
    private var updateCheckTask: Task<Void, Never>?

    /// Retained reference to the onboarding window.
    private var onboardingWindow: NSWindow?

    // MARK: - NSApplicationDelegate

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard ProcessInfo.processInfo.environment["CI_TEST_MODE"] == nil else { return }
        bootstrap()
    }

    // MARK: - Bootstrap

    /// Initializes all services and wires them together.
    ///
    /// Creates the `StateManager` with all dependencies, sets up the menu bar,
    /// registers the hotkey, and starts monitoring tasks.
    private func bootstrap() {
        Log.app.debug("bootstrap — creating services")
        Log.app.debug("bootstrap — SettingsStore created")
        Log.app.debug("bootstrap — PermissionManager created")
        Log.app.debug("bootstrap — AudioEngine created")
        Log.app.debug("bootstrap — WhisperService created")
        Log.app.debug("bootstrap — TextInsertionService created")
        Log.app.debug("bootstrap — HotkeyMonitor created")

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

        Log.app.debug("bootstrap — StateManager initialized")

        // Create menu bar controller (Req 5.1)
        menuBarController = MenuBarController(
            stateManager: sm,
            settingsStore: settingsStore,
            themeEngine: themeEngine,
            hotkeyMonitor: hotkeyMonitor,
            audioEngine: audioEngine,
            whisperService: whisperService,
            permissionManager: permissionManager,
            updateChecker: updateChecker
        )

        // Create recording overlay panel
        overlayPanel = RecordingOverlayPanel(
            stateManager: sm,
            settingsStore: settingsStore,
            themeEngine: themeEngine
        )

        // Register the persisted hotkey (Req 1.3)
        do {
            try hotkeyMonitor.register(
                keyCode: settingsStore.hotkeyKeyCode,
                modifiers: settingsStore.hotkeyModifiers
            )
        } catch {
            Log.hotkey.error("bootstrap — hotkey registration failed: \(error.localizedDescription)")
        }

        // Start theme engine monitoring for appearance / accessibility changes
        themeEngine.startMonitoring()

        // Start observing state to drive overlay visibility (Req 9.1, 9.3, 9.4, 9.5)
        startOverlayObservation(stateManager: sm)

        // Re-register hotkey whenever the user changes it in settings
        startHotkeyObservation()

        // Start permission monitoring
        let permissionManager = self.permissionManager
        permissionMonitoringTask = Task { [permissionManager] in
            await permissionManager.startMonitoringPermissionChanges()
        }

        // Check for app updates (non-blocking, runs in parallel)
        Log.updateChecker.info("Scheduling update check from applicationDidFinishLaunching")
        let updater = updateChecker
        updateCheckTask = Task {
            await updater.checkForUpdate()
            Log.updateChecker.info("Update check task completed — availableUpdate: \(updater.availableUpdate?.version ?? "none")")
        }

        // Requirement 13.1, 13.12: Show onboarding on first launch
        if !settingsStore.onboardingCompleted {
            // During onboarding, model loading happens in the model selection step.
            // Start idle so the hotkey works for the test dictation step.
            sm.markAsReady()
            showOnboardingWindow(stateManager: sm)
        } else {
            // Load the active model on subsequent launches so whisperKit is ready
            Task { await sm.loadActiveModel() }
        }
    }

    /// Called when the user completes onboarding.
    ///
    /// Persists the onboarding-completed flag (Req 13.12) and
    /// dismisses the onboarding window.
    func completeOnboarding() {
        Log.app.debug("completeOnboarding — onboarding finished")

        settingsStore.onboardingCompleted = true
        settingsStore.flush()

        onboardingWindow?.close()
        onboardingWindow = nil

        // Model was already loaded during the onboarding download step
        // (WhisperService.downloadModel loads the model and sets activeModelName).
        // Just ensure we're in idle state.
        stateManager?.markAsReady()
    }

    // MARK: - NSWindowDelegate

    /// Handles the onboarding window being closed (e.g. via the red close button).
    ///
    /// If onboarding was not completed, the app terminates without persisting
    /// the onboarding-completed flag so the wizard reappears on next launch (Req 13.16).
    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              closingWindow === onboardingWindow else { return }
        if !settingsStore.onboardingCompleted {
            NSApplication.shared.terminate(nil)
        }
        onboardingWindow = nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        overlayObservationTask?.cancel()
        hotkeyObservationTask?.cancel()
        permissionMonitoringTask?.cancel()
        updateCheckTask?.cancel()

        // Force UserDefaults to flush to disk before the process exits.
        // Without this, in-memory changes (e.g. onboardingCompleted) can be
        // lost if the app is terminated quickly (Xcode stop, NSApp.terminate).
        settingsStore.flush()
    }

    /// Intercepts the standard "Settings…" (⌘,) menu item so it opens the
    /// real settings window managed by MenuBarController instead of the
    /// empty SwiftUI Settings scene.
    @objc func showSettingsWindow(_ sender: Any?) {
        menuBarController?.openSettings()
    }

    // MARK: - Onboarding Window

    /// Creates and shows the onboarding window using NSWindow + NSHostingController.
    ///
    /// Requirement 13.1: Present a multi-step setup wizard on first launch.
    private func showOnboardingWindow(stateManager sm: StateManager) {
        Log.app.debug("showOnboardingWindow — presenting onboarding wizard")

        let onboardingView = OnboardingFlow(
            whisperService: whisperService,
            onDismiss: { [weak self] in
                self?.completeOnboarding()
            }
        )
        .environment(permissionManager)
        .environment(settingsStore)
        .environment(themeEngine)
        .environment(sm)
        .environment(updateChecker)
        .frame(minWidth: 600, minHeight: 500)

        let hostingController = NSHostingController(rootView: onboardingView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Wispr Setup"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 600, height: 500))
        window.center()
        // Keep the onboarding window above normal windows. Accessory apps
        // (no Dock icon) lose window layering when focus moves to another
        // app (e.g. System Settings for permissions). Floating level
        // ensures the wizard stays visible throughout the setup flow.
        window.level = .floating

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self
        onboardingWindow = window
    }

    // MARK: - Hotkey Settings Observation

    /// Observes `settingsStore.hotkeyKeyCode` and `hotkeyModifiers` and
    /// re-registers the global hotkey whenever the user changes either value.
    private func startHotkeyObservation() {
        hotkeyObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let currentKeyCode = self.settingsStore.hotkeyKeyCode
                let currentModifiers = self.settingsStore.hotkeyModifiers

                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.settingsStore.hotkeyKeyCode
                        _ = self.settingsStore.hotkeyModifiers
                    } onChange: {
                        continuation.resume()
                    }
                }

                // Values changed — re-register with the new combination
                let newKeyCode = self.settingsStore.hotkeyKeyCode
                let newModifiers = self.settingsStore.hotkeyModifiers
                guard newKeyCode != currentKeyCode || newModifiers != currentModifiers else {
                    continue
                }

                do {
                    try self.hotkeyMonitor.updateHotkey(
                        keyCode: newKeyCode,
                        modifiers: newModifiers
                    )
                    Log.app.debug("hotkeyObservation — re-registered hotkey")
                } catch {
                    Log.app.error("hotkeyObservation — failed to re-register hotkey: \(error.localizedDescription)")
                }
            }
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
                // Process current state
                self.updateOverlayVisibility(for: sm.appState)

                // Wait for the next state change, then act immediately
                // in the onChange callback to avoid missing fast transitions
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = sm.appState
                        _ = self.settingsStore.showRecordingOverlay
                    } onChange: {
                        // Resume immediately; the next loop iteration
                        // calls updateOverlayVisibility on @MainActor.
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Shows or dismisses the overlay based on the current app state.
    private func updateOverlayVisibility(for state: AppStateType) {
        switch state {
        case .loading, .recording, .processing, .error:
            if settingsStore.showRecordingOverlay, let overlay = overlayPanel, !overlay.isVisible {
                Log.app.debug("overlayObservation — showing overlay for state: \(state)")
                overlay.show()
            } else if !settingsStore.showRecordingOverlay, let overlay = overlayPanel, overlay.isVisible {
                overlay.dismiss()
            }
        case .idle:
            if let overlay = overlayPanel, overlay.isVisible {
                Log.app.debug("overlayObservation — dismissing overlay")
                overlay.dismiss()
            }
        }
    }
}
