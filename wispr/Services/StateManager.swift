//
//  StateManager.swift
//  wispr
//
//  Central coordinator managing application state transitions.
//  Orchestrates all services and drives UI state.
//  Requirements: 1.1, 1.2, 2.1, 2.2, 3.1, 3.3, 3.4, 4.1, 4.3, 4.4, 9.3, 12.1, 12.5
//

import Foundation
import Observation
import AppKit
import os

/// The central coordinator for the Wispr application.
///
/// `StateManager` owns the application state machine and orchestrates all services.
/// It is `@MainActor` isolated because it drives UI updates, and uses `@Observable`
/// (Observation framework) so SwiftUI views react to state changes automatically.
///
/// **Validates Requirements**: 1.1 (hotkey → recording), 1.2 (hotkey release → end),
/// 3.6 (processing state), 9.3 (overlay state), 12.1 (error handling),
/// 12.5 (concurrent recording prevention)
@MainActor
@Observable
final class StateManager {
    // MARK: - Published State

    /// Current application state driving UI updates.
    var appState: AppStateType = .loading

    /// Current error message displayed to the user, if any.
    var errorMessage: String?

    /// Active transcription language mode.
    var currentLanguage: TranscriptionLanguage = .autoDetect

    /// Audio level stream for the RecordingOverlay to consume.
    /// Set when recording begins, nil when idle.
    var audioLevelStream: AsyncStream<Float>?

    /// Optional custom text shown in the processing overlay.
    /// When nil, the overlay shows the default "Processing..." label.
    var processingStatusText: String?

    // MARK: - Dependencies

    private let audioEngine: AudioEngine
    private let whisperService: any TranscriptionEngine
    private let textInsertionService: any TextInserting
    private let textCorrectionService: any TextCorrecting
    private let hotkeyMonitor: HotkeyMonitor
    private let permissionManager: PermissionManager
    private let settingsStore: SettingsStore
    private let soundFeedback: SoundFeedbackService

    /// Task for auto-dismissing error state after timeout.
    private var errorDismissTask: Task<Void, Never>?

    /// Task for observing settings changes to sync language mode.
    private var languageSyncTask: Task<Void, Never>?

    /// Task for monitoring end-of-utterance detection in hands-free mode.
    private var eouMonitoringTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new StateManager with all required service dependencies.
    ///
    /// - Parameters:
    ///   - audioEngine: The audio capture engine.
    ///   - whisperService: The on-device transcription engine.
    ///   - textInsertionService: The text insertion service.
    ///   - textCorrectionService: The AI text correction service.
    ///   - hotkeyMonitor: The global hotkey monitor.
    ///   - permissionManager: The permission manager.
    ///   - settingsStore: The persistent settings store.
    init(
        audioEngine: AudioEngine,
        whisperService: any TranscriptionEngine,
        textInsertionService: any TextInserting,
        textCorrectionService: any TextCorrecting,
        hotkeyMonitor: HotkeyMonitor,
        permissionManager: PermissionManager,
        settingsStore: SettingsStore
    ) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
        self.textInsertionService = textInsertionService
        self.textCorrectionService = textCorrectionService
        self.hotkeyMonitor = hotkeyMonitor
        self.permissionManager = permissionManager
        self.settingsStore = settingsStore
        self.soundFeedback = SoundFeedbackService(settingsStore: settingsStore)

        // Sync language from persisted settings
        self.currentLanguage = settingsStore.languageMode

        // Wire hotkey callbacks to state machine methods
        setupHotkeyCallbacks()

        // Observe settings changes to keep language in sync
        // Requirement 16.9: Language changes during idle apply to next recording
        startLanguageSync()
    }

    // MARK: - Language Sync

    /// Observes `settingsStore.languageMode` and syncs to `currentLanguage`.
    ///
    /// This ensures that language changes made from SettingsView (which only
    /// updates `settingsStore`) are reflected in `currentLanguage` used during
    /// transcription.
    ///
    /// **Validates**: Requirement 16.9
    private func startLanguageSync() {
        languageSyncTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let mode = self.settingsStore.languageMode
                if self.currentLanguage != mode {
                    self.currentLanguage = mode
                }
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.settingsStore.languageMode
                    } onChange: {
                        continuation.resume()
                    }
                }
            }
        }
    }

    // MARK: - Hotkey Wiring

    /// Connects HotkeyMonitor events to the state machine.
    ///
    /// **Validates**: Requirement 1.1 (hotkey down → begin recording),
    /// Requirement 1.2 (hotkey up → end recording)
    private func setupHotkeyCallbacks() {
        hotkeyMonitor.onHotkeyDown = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if self.settingsStore.handsFreeMode {
                    await self.toggleRecording()
                } else {
                    await self.beginRecording()
                }
            }
        }

        hotkeyMonitor.onHotkeyUp = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                if !self.settingsStore.handsFreeMode {
                    await self.endRecording()
                }
                // In hands-free mode, key-up is intentionally ignored.
            }
        }
    }

    // MARK: - Hands-Free Toggle

    /// Toggles recording state for hands-free mode.
    /// If idle, starts recording (with EOU monitoring when supported).
    /// If recording, stops recording.
    /// If in error state, dismisses the error and starts a new recording (issue #52).
    /// Ignores calls during .loading or .processing states.
    func toggleRecording() async {
        switch appState {
        case .idle:
            await beginRecording()
        case .recording:
            cancelEouMonitoring()
            await endRecording()
        case .loading, .processing:
            break
        case .error:
            // Issue #52: dismiss error and start new recording
            await resetToIdle()
            await beginRecording()
        }
    }

    // MARK: - EOU Monitoring

    /// Checks if the active transcription engine supports EOU detection
    /// and, if so, starts a background task that monitors for end-of-utterance.
    private func startEouMonitoringIfSupported() async {
        let supportsEou = await whisperService.supportsEndOfUtteranceDetection()
        guard supportsEou else { return }

        eouMonitoringTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let resultStream = await self.whisperService.transcribeStream(
                    await self.audioEngine.captureStream,
                    language: self.currentLanguage
                )

                var finalResult: TranscriptionResult?
                for try await result in resultStream {
                    if result.isEndOfUtterance {
                        finalResult = result
                        break
                    }
                }

                guard let finalResult, !Task.isCancelled, self.appState == .recording else {
                    return
                }

                // Transition to .processing BEFORE the await so that a concurrent
                // endRecording() (from the user pressing the hotkey at the same
                // instant EOU fires) sees .processing and bails out via its
                // `guard appState == .recording` check.
                self.appState = .processing
                self.audioLevelStream = nil

                await self.audioEngine.cancelCapture()

                NSAccessibility.post(
                    element: NSApp as Any,
                    notification: .announcementRequested,
                    userInfo: [.announcement: "Speech ended, processing"]
                )

                self.soundFeedback.play(.recordingStopped)

                await self.insertTranscribedText(finalResult.text)
            } catch {
                guard !Task.isCancelled else { return }
                Log.stateManager.warning("EOU monitoring failed: \(error.localizedDescription)")
            }
        }
    }

    /// Cancels any active EOU monitoring task.
    private func cancelEouMonitoring() {
        eouMonitoringTask?.cancel()
        eouMonitoringTask = nil
    }

    // MARK: - Filler Word Removal

    /// Removes filler words from transcribed text when the setting is enabled.
    func applyFillerWordRemoval(to text: String) -> String {
        guard settingsStore.removeFillerWords, !text.isEmpty else { return text }
        return FillerWordCleaner.clean(text)
    }

    // MARK: - AI Text Correction

    /// Applies AI text correction if enabled and available.
    /// Returns the corrected text, or the original text if disabled, unavailable, or on failure.
    private func applyAITextCorrection(to text: String) async -> String {
        guard settingsStore.aiTextCorrectionEnabled,
              textCorrectionService.availability == .available,
              !text.isEmpty else { return text }
        processingStatusText = "Correcting…"
        let corrected = await textCorrectionService.correctText(
            text,
            style: settingsStore.aiTextCorrectionStyle
        )
        processingStatusText = nil
        return corrected
    }

    // MARK: - Auto-Suffix & Auto-Send Helpers

    /// Applies optional suffix to transcribed text based on settings.
    ///
    /// Returns `text + autoSuffixText` when the feature is enabled and both
    /// strings are non-empty; otherwise returns the original text unchanged.
    ///
    /// **Validates**: Requirements 3.1, 3.2, 3.3
    func applyAutoSuffix(to text: String) -> String {
        guard settingsStore.autoSuffixEnabled,
              !text.isEmpty,
              !settingsStore.autoSuffixText.isEmpty else {
            return text
        }
        return text + settingsStore.autoSuffixText
    }

    /// Simulates Enter keystroke if auto-send is enabled.
    ///
    /// **Validates**: Requirements 5.6, 5.7
    func applyAutoSendEnter() {
        guard settingsStore.autoSendEnterEnabled else { return }
        textInsertionService.simulateEnterKey()
    }

    // MARK: - Post-Transcription Pipeline

    /// Shared post-transcription pipeline: applies suffix, inserts text,
    /// optionally sends Enter, announces to VoiceOver, and resets to idle.
    ///
    /// On insertion failure, copies the text to the clipboard as a fallback.
    ///
    /// Called by both `endRecording()` and the EOU handler to avoid duplication.
    ///
    /// **Validates**: Requirements 3.1, 3.2, 3.3, 3.4, 4.1, 4.3, 4.4, 5.6, 5.7, 5.9
    func insertTranscribedText(_ text: String) async {
        guard !text.isEmpty else {
            await resetToIdle()
            return
        }

        let cleaned = applyFillerWordRemoval(to: text)

        // If filler removal left the text empty, treat as empty transcription
        guard !cleaned.isEmpty else {
            await resetToIdle()
            return
        }

        // AI text correction step (after filler removal, before suffix)
        let corrected = await applyAITextCorrection(to: cleaned)

        let finalText = applyAutoSuffix(to: corrected)

        do {
            try await textInsertionService.insertText(finalText)

            applyAutoSendEnter()

            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: "Text inserted"]
            )
            await resetToIdle()
        } catch {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(finalText, forType: .string)
            await handleError(
                .textInsertionFailed(
                    "Text insertion failed. The transcribed text has been copied to your clipboard for manual pasting."
                )
            )
        }
    }

    // MARK: - State Machine

    /// Begins a new recording session.
    ///
    /// Transitions from `.idle` to `.recording`, starts audio capture,
    /// and exposes the audio level stream for the overlay.
    ///
    /// **Validates**: Requirement 1.1, 2.1, 12.5 (concurrent recording prevention)
    func beginRecording() async {
        // Requirement 12.5: Prevent concurrent recording sessions.
        // Only allow starting a new recording from the idle state.
        // Ignore the request if already recording, processing, or still loading.
        // Issue #52: If in error state, dismiss the error and proceed.
        if case .error = appState {
            await resetToIdle()
        }
        guard appState == .idle else {
            if appState == .loading {
                Log.stateManager.debug("beginRecording — still loading, ignoring hotkey")
            }
            return
        }

        // Check permissions before starting
        // If microphone permission is not determined, request it first
        if permissionManager.microphoneStatus == .notDetermined {
            Log.stateManager.debug("beginRecording — microphone permission not determined, requesting...")
            let granted = await permissionManager.requestMicrophoneAccess()
            if !granted {
                Log.stateManager.warning("beginRecording — microphone permission denied by user")
                // User just denied in the dialog - show error but don't open Settings yet
                // They just saw the dialog, so they know what happened
                appState = .error("Microphone access denied")
                errorMessage = "Microphone access denied"
                
                // Auto-dismiss after 3 seconds
                errorDismissTask?.cancel()
                errorDismissTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    await self?.resetToIdle()
                }
                return
            }
        }
        
        // Now check if all permissions are granted
        guard permissionManager.allPermissionsGranted else {
            Log.stateManager.warning("beginRecording — permissions not granted, aborting")
            // Permission was previously denied — open the appropriate System Settings pane
            if permissionManager.microphoneStatus == .denied {
                await handleError(.microphonePermissionDenied)
            } else {
                await handleError(.accessibilityPermissionDenied)
            }
            return
        }

        Log.stateManager.debug("beginRecording — transitioning .idle → .recording")

        // Transition to recording state
        appState = .recording
        errorMessage = nil

        soundFeedback.play(.recordingStarted)

        // Requirement 17.3, 17.11: Announce state change to assistive technologies
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Recording started"]
        )

        do {
            // Requirement 8.2: Use the user's selected input device.
            // Always set the device (including nil) so a previously-selected
            // device doesn't persist when the user switches back to "System Default"
            // or the saved device is no longer available.
            if let deviceUID = settingsStore.selectedAudioDeviceUID,
               let deviceID = await audioEngine.deviceIDForUID(deviceUID) {
                try await audioEngine.setInputDevice(deviceID)
            } else {
                if let uid = settingsStore.selectedAudioDeviceUID {
                    Log.stateManager.debug("beginRecording — selected device UID '\(uid)' not found, falling back to system default")
                }
                try await audioEngine.setInputDevice(nil)
            }

            // Requirement 2.1: Start audio capture
            let levelStream = try await audioEngine.startCapture()
            audioLevelStream = levelStream
            // Start EOU monitoring only in hands-free mode.
            // Push-to-talk users control duration by holding the key,
            // so auto-stopping on silence would be unexpected.
            if settingsStore.handsFreeMode {
                await startEouMonitoringIfSupported()
            }
        } catch let error as WisprError {
            await handleError(error)
        } catch {
            await handleError(.audioRecordingFailed(error.localizedDescription))
        }
    }

    /// Ends the current recording session.
    ///
    /// Stops audio capture, transitions to `.processing`, runs transcription,
    /// inserts text, then returns to `.idle`.
    ///
    /// **Validates**: Requirement 1.2, 2.2, 3.1, 3.3, 3.4, 4.1, 4.3, 4.4
    ///
    /// ## Privacy (Requirements 11.1–11.4)
    ///
    /// The end-to-end flow preserves privacy at every step:
    /// 1. `AudioEngine.stopCapture()` returns in-memory audio samples and
    ///    immediately clears its internal buffer — no temp files are created.
    /// 2. `WhisperService.transcribe()` processes audio entirely on-device
    ///    via WhisperKit/CoreML — no network calls.
    /// 3. `TextInsertionService.insertText()` inserts text at the cursor and
    ///    discards it — no logging or persistence of transcribed content.
    /// 4. The local `audioSamples` and `result` variables are released when
    ///    this method returns, leaving no residual data in memory.
    func endRecording() async {
        // Only end if we're actually recording
        guard appState == .recording else { return }

        // Cancel any active EOU monitoring so it doesn't race with this path
        cancelEouMonitoring()

        // Requirement 2.2: Stop capture and get audio samples
        let audioSamples = await audioEngine.stopCapture()
        audioLevelStream = nil

        Log.stateManager.debug("endRecording — received \(audioSamples.count) samples from stopCapture()")

        // Requirement 3.6: Transition to processing
        appState = .processing

        soundFeedback.play(.recordingStopped)

        // Requirement 17.3, 17.11: Announce state change to assistive technologies
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Processing speech"]
        )

        // Guard against empty audio
        guard !audioSamples.isEmpty else {
            Log.stateManager.debug("endRecording — audio samples empty, returning to idle")
            await resetToIdle()
            return
        }

        do {
            // Requirement 3.1, 3.3: Transcribe audio
            let result = try await whisperService.transcribe(
                audioSamples,
                language: currentLanguage
            )

            #if DEBUG
            let preview = String(result.text.prefix(50))
            Log.stateManager.debug("endRecording — transcription: \"\(preview, privacy: .private)\" (len=\(result.text.count))")
            #endif

            await insertTranscribedText(result.text)

        } catch WisprError.emptyTranscription {
            // Requirement 3.4: Empty transcription — notify user and return to idle
            await handleError(.emptyTranscription)
        } catch let error as WisprError {
            await handleError(error)
        } catch {
            await handleError(.transcriptionFailed(error.localizedDescription))
        }
    }

    /// Handles an error by transitioning to the error state.
    ///
    /// Displays the error message and automatically returns to `.idle`
    /// after ~5 seconds.
    ///
    /// For permission errors, also opens System Settings to help the user fix the issue.
    ///
    /// **Validates**: Requirement 12.1
    func handleError(_ error: WisprError) async {
        Log.stateManager.error("handleError — \(error.localizedDescription)")

        // Cancel any pending audio capture
        await audioEngine.cancelCapture()
        audioLevelStream = nil

        let message = error.localizedDescription
        appState = .error(message)
        errorMessage = message

        // Requirement 17.3, 17.11: Announce error to assistive technologies
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Error: \(message)"]
        )
        
        // For permission errors, open System Settings to help user fix the issue
        // (We only reach here if permission was already denied, since .notDetermined
        // is handled in beginRecording() by requesting permission first)
        switch error {
        case .microphonePermissionDenied:
            permissionManager.openMicrophoneSettings()
        case .accessibilityPermissionDenied:
            permissionManager.openAccessibilitySettings()
        default:
            break
        }

        // Cancel any existing error dismiss timer
        errorDismissTask?.cancel()

        // Requirement 12.1: Auto-dismiss error after ~5 seconds
        errorDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(5))
            } catch {
                return // Cancelled
            }
            guard let self else { return }
            // Only reset if still in error state (user may have already dismissed)
            if case .error = self.appState {
                await self.resetToIdle()
            }
        }
    }

    /// Resets the application to the idle state.
    ///
    /// Cleans up any active recording or processing and returns to `.idle`.
    ///
    /// **Validates**: Requirement 12.1
    func resetToIdle() async {
        errorDismissTask?.cancel()
        errorDismissTask = nil
        cancelEouMonitoring()
        appState = .idle
        errorMessage = nil
        audioLevelStream = nil
    }
    
    /// Marks the app as ready after model loading completes.
    /// Transitions from `.loading` to `.idle`.
    func markAsReady() {
        if appState == .loading {
            appState = .idle
            Log.stateManager.debug("markAsReady — app ready for dictation")
        }
    }

    /// Switches the active transcription model.
    ///
    /// Unloads the current model, loads the new one, and persists the choice.
    /// Used by both SettingsView and ModelManagementView.
    ///
    /// - Parameter modelName: The model ID to switch to.
    /// - Throws: Propagates errors from the transcription engine.
    func switchActiveModel(to modelName: String) async throws {
        guard modelName != settingsStore.activeModelName else { return }
        Log.stateManager.debug("switchActiveModel — switching to '\(modelName)'")
        try await whisperService.switchModel(to: modelName)
        settingsStore.activeModelName = modelName
        Log.stateManager.debug("switchActiveModel — '\(modelName)' active")
    }

    /// Loads the persisted active model at startup.
    ///
    /// Transitions `.loading` → `.idle` on success, or `.loading` → `.error` → `.idle`
    /// on failure (auto-dismisses after 5 seconds so the app remains usable).
    func loadActiveModel() async {
        let modelName = settingsStore.activeModelName
        guard !modelName.isEmpty else {
            markAsReady()
            return
        }
        appState = .loading
        do {
            Log.stateManager.debug("loadActiveModel — loading '\(modelName)'")
            try await whisperService.loadModel(modelName)
            Log.stateManager.debug("loadActiveModel — '\(modelName)' loaded successfully")
            markAsReady()
        } catch {
            Log.stateManager.error("loadActiveModel — failed to load '\(modelName)': \(error.localizedDescription)")
            appState = .error("Failed to load model — open Model Management to fix")
            errorMessage = "Failed to load model — open Model Management to fix"
            // Auto-dismiss to idle after 5 seconds so the app remains usable
            try? await Task.sleep(for: .seconds(5))
            if case .error = appState {
                appState = .idle
                errorMessage = nil
            }
        }
    }
}
