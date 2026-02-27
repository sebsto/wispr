//
//  MenuBarController.swift
//  wispr
//
//  Manages the NSStatusItem menu bar presence, template icon, and dropdown menu.
//  Bridges to SwiftUI views for settings, model management, and language selection.
//  Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 14.2, 14.9, 16.7, 16.8
//

import AppKit
import SwiftUI
import Observation

/// Manages the NSStatusItem in the macOS menu bar.
///
/// Creates the status item on init, sets a template SF Symbol icon that reflects
/// the current application state, and builds a dropdown menu with recording,
/// settings, model management, language selection, and quit actions.
///
/// **Validates Requirements**: 5.1 (NSStatusItem creation), 5.2 (icon state),
/// 5.3 (dropdown menu), 5.4 (start/stop recording), 5.5 (quit with cleanup),
/// 14.2 (template icon), 14.9 (smooth icon transitions), 16.7 (language display),
/// 16.8 (language selection in menu)
@MainActor
final class MenuBarController {

    // MARK: - Properties

    /// The macOS menu bar status item.
    private let statusItem: NSStatusItem

    /// The dropdown menu displayed when the user clicks the status item.
    private let menu: NSMenu

    /// Reference to the central state manager for wiring actions.
    private let stateManager: StateManager

    /// Reference to settings for language display.
    private let settingsStore: SettingsStore

    /// Theme engine for SF Symbol helpers.
    private let themeEngine: UIThemeEngine

    /// Audio engine for settings view.
    private let audioEngine: AudioEngine

    /// Whisper service for settings and model management views.
    private let whisperService: WhisperService

    /// Permission manager for settings view.
    private let permissionManager: PermissionManager

    /// Observation tracking for state changes.
    private var observationTask: Task<Void, Never>?

    /// Key used for the Core Animation pulse on the status button during processing.
    private static let processingAnimationKey = "wisp.processing.pulse"

    /// Retained reference to the settings window.
    private var settingsWindow: NSWindow?

    /// Retained reference to the model management window.
    private var modelManagementWindow: NSWindow?

    // MARK: - Menu Items (retained for dynamic updates)

    private let recordingMenuItem = NSMenuItem()
    private let languageMenuItem = NSMenuItem()
    private let languageSubmenu = NSMenu()

    // MARK: - Initialization

    /// Creates the MenuBarController and sets up the status item, icon, and menu.
    ///
    /// - Parameters:
    ///   - stateManager: The central state coordinator.
    ///   - settingsStore: The persistent settings store.
    ///   - themeEngine: The UI theme engine for SF Symbol helpers.
    ///   - audioEngine: The audio engine (needed for SettingsView).
    ///   - whisperService: The whisper service (needed for SettingsView and ModelManagementView).
    ///   - permissionManager: The permission manager (needed for SettingsView).
    init(
        stateManager: StateManager,
        settingsStore: SettingsStore,
        themeEngine: UIThemeEngine = .shared,
        audioEngine: AudioEngine,
        whisperService: WhisperService,
        permissionManager: PermissionManager
    ) {
        self.stateManager = stateManager
        self.settingsStore = settingsStore
        self.themeEngine = themeEngine
        self.audioEngine = audioEngine
        self.whisperService = whisperService
        self.permissionManager = permissionManager

        // Requirement 5.1: Create NSStatusItem in the menu bar
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.menu = NSMenu()

        configureStatusButton()
        buildMenu()
        startObservingState()
    }

    // MARK: - Status Button Configuration

    /// Configures the status item button with the initial template icon.
    ///
    /// Requirement 14.2: Template image that appears sharp at all Retina resolutions.
    /// NSImage(systemSymbolName:) provides @1x, @2x, @3x automatically.
    private func configureStatusButton() {
        guard let button = statusItem.button else { return }

        let symbolName = themeEngine.menuBarSymbol(for: .idle)
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Wisp Voice Dictation"
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Wisp — Voice Dictation"

        statusItem.menu = menu
    }

    // MARK: - Menu Construction

    /// Builds the dropdown menu with all required items.
    ///
    /// Requirement 5.3: Menu contains Start/Stop Recording, Settings,
    /// Model Management, Language Selection, and Quit.
    private func buildMenu() {
        menu.removeAllItems()

        // Start/Stop Recording
        updateRecordingMenuItem()
        menu.addItem(recordingMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Language Selection
        languageMenuItem.title = languageDisplayTitle()
        languageMenuItem.image = NSImage(
            systemSymbolName: themeEngine.actionSymbol(.language),
            accessibilityDescription: "Language"
        )
        languageMenuItem.submenu = languageSubmenu
        buildLanguageSubmenu()
        menu.addItem(languageMenuItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(MenuBarActionHandler.openSettings(_:)),
            keyEquivalent: ","
        )
        settingsItem.image = NSImage(
            systemSymbolName: themeEngine.actionSymbol(.settings),
            accessibilityDescription: "Settings"
        )
        menu.addItem(settingsItem)

        // Model Management
        let modelItem = NSMenuItem(
            title: "Model Management…",
            action: #selector(MenuBarActionHandler.openModelManagement(_:)),
            keyEquivalent: ""
        )
        modelItem.image = NSImage(
            systemSymbolName: themeEngine.actionSymbol(.model),
            accessibilityDescription: "Model Management"
        )
        menu.addItem(modelItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Wisp",
            action: #selector(MenuBarActionHandler.quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.image = NSImage(
            systemSymbolName: themeEngine.actionSymbol(.quit),
            accessibilityDescription: "Quit"
        )
        menu.addItem(quitItem)

        // Set the shared action handler as the target for all items
        let handler = MenuBarActionHandler.shared
        handler.menuBarController = self
        for item in menu.items where item.action != nil {
            item.target = handler
        }
    }

    // MARK: - Recording Menu Item

    /// Updates the recording menu item title and action based on current state.
    private func updateRecordingMenuItem() {
        let isRecording = stateManager.appState == .recording

        recordingMenuItem.title = isRecording ? "Stop Recording" : "Start Recording"
        recordingMenuItem.action = #selector(MenuBarActionHandler.toggleRecording(_:))
        recordingMenuItem.target = MenuBarActionHandler.shared

        let symbolName = isRecording
            ? themeEngine.menuBarSymbol(for: .recording)
            : themeEngine.menuBarSymbol(for: .idle)
        recordingMenuItem.image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: isRecording ? "Stop Recording" : "Start Recording"
        )

        // Disable during processing
        recordingMenuItem.isEnabled = stateManager.appState != .processing
    }

    // MARK: - Language Display

    /// Returns the display title for the language menu item.
    ///
    /// Requirement 16.7: Display current language or auto-detect indicator.
    private func languageDisplayTitle() -> String {
        switch settingsStore.languageMode {
        case .autoDetect:
            return "Language: Auto-Detect"
        case .specific(let code):
            return "Language: \(languageDisplayName(for: code))"
        case .pinned(let code):
            return "Language: \(languageDisplayName(for: code)) (Pinned)"
        }
    }

    /// Returns a human-readable name for a language code.
    private func languageDisplayName(for code: String) -> String {
        let locale = Locale.current
        return locale.localizedString(forLanguageCode: code)?.capitalized ?? code.uppercased()
    }

    // MARK: - Language Submenu

    /// Builds the language selection submenu.
    ///
    /// Requirement 16.8: Language selection control in the menu bar dropdown.
    private func buildLanguageSubmenu() {
        languageSubmenu.removeAllItems()

        // Auto-Detect option
        let autoItem = NSMenuItem(
            title: "Auto-Detect",
            action: #selector(MenuBarActionHandler.selectAutoDetect(_:)),
            keyEquivalent: ""
        )
        autoItem.target = MenuBarActionHandler.shared
        if settingsStore.languageMode.isAutoDetect {
            autoItem.state = .on
        }
        languageSubmenu.addItem(autoItem)

        languageSubmenu.addItem(NSMenuItem.separator())

        // Common languages
        let commonLanguages: [(code: String, name: String)] = [
            ("en", "English"),
            ("es", "Spanish"),
            ("fr", "French"),
            ("de", "German"),
            ("it", "Italian"),
            ("pt", "Portuguese"),
            ("nl", "Dutch"),
            ("ja", "Japanese"),
            ("ko", "Korean"),
            ("zh", "Chinese"),
            ("ru", "Russian"),
            ("ar", "Arabic"),
            ("hi", "Hindi"),
        ]

        for lang in commonLanguages {
            let item = NSMenuItem(
                title: lang.name,
                action: #selector(MenuBarActionHandler.selectLanguage(_:)),
                keyEquivalent: ""
            )
            item.target = MenuBarActionHandler.shared
            item.representedObject = lang.code

            // Mark the currently selected language
            if let currentCode = settingsStore.languageMode.languageCode,
               currentCode == lang.code {
                item.state = .on
            }
            languageSubmenu.addItem(item)
        }
    }

    // MARK: - Icon State Updates

    /// Updates the menu bar icon to reflect the current application state.
    ///
    /// Requirement 5.2: Icon reflects idle, recording, or processing state.
    /// Requirement 14.9: Smooth icon transitions on state change.
    private func updateIcon(for state: AppStateType) {
        guard let button = statusItem.button else { return }

        let symbolName = themeEngine.menuBarSymbol(for: state)
        let description: String
        switch state {
        case .idle:
            description = "Wisp — Idle"
        case .recording:
            description = "Wisp — Recording"
        case .processing:
            description = "Wisp — Processing"
        case .error:
            description = "Wisp — Error"
        }

        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: description
        )
        image?.isTemplate = true
        button.image = image
        button.toolTip = description

        // Drive animation via Core Animation (runs on the render server,
        // zero main-thread or Swift Concurrency executor overhead).
        if state == .processing {
            startProcessingAnimation()
        } else {
            stopProcessingAnimation()
        }
    }

    // MARK: - Processing Animation (Core Animation)

    /// Adds a subtle opacity pulse to the status button using Core Animation.
    ///
    /// CA animations run on the macOS render server (a separate process),
    /// so they have zero impact on the main thread or Swift Concurrency
    /// cooperative executor — WhisperKit.transcribe() won't be starved.
    ///
    /// Respects `themeEngine.reduceMotion`.
    private func startProcessingAnimation() {
        guard let button = statusItem.button else { return }
        guard !themeEngine.reduceMotion else { return }
        guard button.layer?.animation(forKey: Self.processingAnimationKey) == nil else { return }

        button.wantsLayer = true
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        button.layer?.add(pulse, forKey: Self.processingAnimationKey)
    }

    /// Removes the processing pulse animation.
    private func stopProcessingAnimation() {
        guard let button = statusItem.button else { return }
        button.layer?.removeAnimation(forKey: Self.processingAnimationKey)
    }

    // MARK: - State Observation

    /// Starts observing StateManager for app state changes to update the icon and menu.
    private func startObservingState() {
        observationTask = Task { [weak self] in
            guard let self else { return }
            // Use withObservationTracking in a loop to react to state changes
            while !Task.isCancelled {
                let currentState = self.stateManager.appState
                _ = self.settingsStore.languageMode

                self.updateIcon(for: currentState)
                self.updateRecordingMenuItem()
                self.languageMenuItem.title = self.languageDisplayTitle()
                self.buildLanguageSubmenu()

                // Wait for the next change using Observation framework
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.stateManager.appState
                        _ = self.settingsStore.languageMode
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    /// Stops observation and cleans up.
    func stopObserving() {
        observationTask?.cancel()
        observationTask = nil
        stopProcessingAnimation()
    }

    // MARK: - Actions (called by MenuBarActionHandler)

    /// Toggles recording on/off.
    ///
    /// Requirement 5.4: Start/Stop Recording from menu.
    func toggleRecording() {
        Task {
            if stateManager.appState == .recording {
                await stateManager.endRecording()
            } else {
                await stateManager.beginRecording()
            }
        }
    }

    /// Opens the Settings window.
    ///
    /// Creates an NSWindow hosting the SwiftUI SettingsView if one doesn't
    /// already exist, or brings the existing one to front.
    func openSettings() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = settingsWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let settingsView = SettingsView(
            audioEngine: audioEngine,
            whisperService: whisperService
        )
        .environment(settingsStore)
        .environment(themeEngine)
        .environment(stateManager)
        .environment(permissionManager)

        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Wisp Settings"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 560, height: 580))
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    /// Opens the Model Management window.
    ///
    /// Creates an NSWindow hosting the SwiftUI ModelManagementView if one doesn't
    /// already exist, or brings the existing one to front.
    func openModelManagement() {
        NSApp.activate(ignoringOtherApps: true)

        if let window = modelManagementWindow, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            return
        }

        let modelView = ModelManagementView(whisperService: whisperService)
            .environment(settingsStore)
            .environment(themeEngine)
            .environment(stateManager)

        let hostingController = NSHostingController(rootView: modelView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Model Management"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 540, height: 480))
        window.center()
        window.makeKeyAndOrderFront(nil)
        modelManagementWindow = window
    }

    /// Sets language to auto-detect mode.
    ///
    /// Requirement 16.8: Language selection from menu.
    func selectAutoDetect() {
        settingsStore.languageMode = .autoDetect
        stateManager.currentLanguage = .autoDetect
    }

    /// Sets a specific language for transcription.
    ///
    /// Requirement 16.8: Language selection from menu.
    func selectLanguage(_ code: String) {
        let mode = TranscriptionLanguage.specific(code: code)
        settingsStore.languageMode = mode
        stateManager.currentLanguage = mode
    }

    /// Quits the application after cleaning up resources.
    ///
    /// Requirement 5.5: Clean up all resources and terminate.
    func quitApp() {
        stopObserving()
        NSApp.terminate(nil)
    }
}

// MARK: - Menu Action Handler

/// A helper class that bridges NSMenuItem target-action to MenuBarController.
///
/// NSMenuItem requires an `@objc` target. This is one of the unavoidable
/// AppKit bridging points per Requirement 15.7.
final class MenuBarActionHandler: NSObject {
    static let shared = MenuBarActionHandler()

    /// Weak reference to the MenuBarController to forward actions.
    weak var menuBarController: MenuBarController?

    @MainActor
    @objc func toggleRecording(_ sender: NSMenuItem) {
        menuBarController?.toggleRecording()
    }

    @MainActor
    @objc func openSettings(_ sender: NSMenuItem) {
        menuBarController?.openSettings()
    }

    @MainActor
    @objc func openModelManagement(_ sender: NSMenuItem) {
        menuBarController?.openModelManagement()
    }

    @MainActor
    @objc func selectAutoDetect(_ sender: NSMenuItem) {
        menuBarController?.selectAutoDetect()
    }

    @MainActor
    @objc func selectLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        menuBarController?.selectLanguage(code)
    }

    @MainActor
    @objc func quitApp(_ sender: NSMenuItem) {
        menuBarController?.quitApp()
    }
}
