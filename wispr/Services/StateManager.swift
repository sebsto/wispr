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

/// The central coordinator for the Wisp application.
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
    var appState: AppStateType = .idle

    /// Current error message displayed to the user, if any.
    var errorMessage: String?

    /// Active transcription language mode.
    var currentLanguage: TranscriptionLanguage = .autoDetect

    /// Audio level stream for the RecordingOverlay to consume.
    /// Set when recording begins, nil when idle.
    var audioLevelStream: AsyncStream<Float>?

    // MARK: - Dependencies

    private let audioEngine: AudioEngine
    private let whisperService: WhisperService
    private let textInsertionService: TextInsertionService
    private let hotkeyMonitor: HotkeyMonitor
    private let permissionManager: PermissionManager
    private let settingsStore: SettingsStore

    /// Task for auto-dismissing error state after timeout.
    private var errorDismissTask: Task<Void, Never>?

    /// Task for observing settings changes to sync language mode.
    private var languageSyncTask: Task<Void, Never>?

    // MARK: - Initialization

    /// Creates a new StateManager with all required service dependencies.
    ///
    /// - Parameters:
    ///   - audioEngine: The audio capture engine.
    ///   - whisperService: The on-device transcription service.
    ///   - textInsertionService: The text insertion service.
    ///   - hotkeyMonitor: The global hotkey monitor.
    ///   - permissionManager: The permission manager.
    ///   - settingsStore: The persistent settings store.
    init(
        audioEngine: AudioEngine,
        whisperService: WhisperService,
        textInsertionService: TextInsertionService,
        hotkeyMonitor: HotkeyMonitor,
        permissionManager: PermissionManager,
        settingsStore: SettingsStore
    ) {
        self.audioEngine = audioEngine
        self.whisperService = whisperService
        self.textInsertionService = textInsertionService
        self.hotkeyMonitor = hotkeyMonitor
        self.permissionManager = permissionManager
        self.settingsStore = settingsStore

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
                await self.beginRecording()
            }
        }

        hotkeyMonitor.onHotkeyUp = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.endRecording()
            }
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
        // Ignore the request if already recording, processing, or showing an error.
        guard appState == .idle else { return }

        // Check permissions before starting
        guard permissionManager.allPermissionsGranted else {
            Log.stateManager.warning("beginRecording — permissions not granted, aborting")
            await handleError(.microphonePermissionDenied)
            return
        }

        Log.stateManager.debug("beginRecording — transitioning .idle → .recording")

        // Transition to recording state
        appState = .recording
        errorMessage = nil

        // Requirement 17.3, 17.11: Announce state change to assistive technologies
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: "Recording started"]
        )

        do {
            // Requirement 2.1: Start audio capture
            let levelStream = try await audioEngine.startCapture()
            audioLevelStream = levelStream
        } catch let error as WispError {
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

        // Requirement 2.2: Stop capture and get audio samples
        let audioSamples = await audioEngine.stopCapture()
        audioLevelStream = nil

        Log.stateManager.debug("endRecording — received \(audioSamples.count) samples from stopCapture()")

        // Requirement 3.6: Transition to processing
        appState = .processing

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

            // Requirement 3.4: Empty transcription returns to idle without inserting
            guard !result.text.isEmpty else {
                await resetToIdle()
                return
            }

            // Requirement 4.1, 4.3: Insert transcribed text
            do {
                try await textInsertionService.insertText(result.text)
                Log.stateManager.debug("endRecording — text inserted successfully")
            } catch {
                // Requirement 4.4: On insertion failure, retain text on pasteboard and notify
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(result.text, forType: .string)
                await handleError(
                    .textInsertionFailed(
                        "Text insertion failed. The transcribed text has been copied to your clipboard for manual pasting."
                    )
                )
                return
            }

            // Requirement 4.3: Transition to idle on success
            // Requirement 17.3, 17.11: Announce text insertion to assistive technologies
            NSAccessibility.post(
                element: NSApp as Any,
                notification: .announcementRequested,
                userInfo: [.announcement: "Text inserted"]
            )
            await resetToIdle()

        } catch WispError.emptyTranscription {
            // Requirement 3.4: Empty transcription — notify user and return to idle
            await handleError(.emptyTranscription)
        } catch let error as WispError {
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
    /// **Validates**: Requirement 12.1
    func handleError(_ error: WispError) async {
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
        appState = .idle
        errorMessage = nil
        audioLevelStream = nil
    }
}
