//
//  MeetingDetectionService.swift
//  wispr
//
//  Coordinates CoreAudio input-activity detection with an actionable local
//  notification, so the user is prompted to start meeting transcription when a
//  meeting begins.
//

import Foundation
import Observation
import WisprCore
import os

/// Watches for the start of a meeting (another process using the microphone)
/// and posts a notification inviting the user to start transcription.
///
/// The heavy lifting lives behind two protocols (`InputActivityMonitoring`,
/// `MeetingNotifying`) so this coordination logic is fully unit-testable.
@MainActor
final class MeetingDetectionService {

    // MARK: - Dependencies

    private let settingsStore: SettingsStore
    private let monitor: any InputActivityMonitoring
    private let notifier: any MeetingNotifying

    /// Returns `true` when Wispr itself is using the microphone (dictation or an
    /// active meeting recording), so self-triggered activity is ignored.
    /// Injected by the app delegate; defaults to "not using".
    var isSelfUsingMicrophone: @MainActor () -> Bool = { false }

    // MARK: - Configuration

    /// Minimum interval between two meeting-detected notifications.
    private let cooldown: TimeInterval

    // MARK: - State

    private var isMonitoring = false
    private var lastRunningState = false
    private var lastNotificationDate: Date?
    private var settingsObservationTask: Task<Void, Never>?

    // MARK: - Init

    init(
        settingsStore: SettingsStore,
        notifier: any MeetingNotifying,
        monitor: any InputActivityMonitoring = AudioInputActivityMonitor(),
        cooldown: TimeInterval = 5 * 60
    ) {
        self.settingsStore = settingsStore
        self.notifier = notifier
        self.monitor = monitor
        self.cooldown = cooldown
    }

    // MARK: - Lifecycle

    /// Starts observing the setting and, if enabled, begins monitoring.
    func start() {
        applyMonitoringState()
        observeSettings()
    }

    /// Stops all observation and monitoring.
    func stop() {
        settingsObservationTask?.cancel()
        settingsObservationTask = nil
        stopMonitoring()
    }

    // MARK: - Settings Observation

    private func observeSettings() {
        settingsObservationTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await withCheckedContinuation { continuation in
                    withObservationTracking {
                        _ = self.settingsStore.meetingDetectionEnabled
                    } onChange: {
                        continuation.resume()
                    }
                }
                self.applyMonitoringState()
            }
        }
    }

    private func applyMonitoringState() {
        if settingsStore.meetingDetectionEnabled {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    // MARK: - Monitoring

    private func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        lastRunningState = false

        notifier.requestAuthorization()

        monitor.start { [weak self] running in
            // Listener may fire on an arbitrary queue — hop to the main actor.
            Task { @MainActor in
                self?.handleActivityChange(running)
            }
        }
        Log.app.debug("MeetingDetectionService — monitoring started")
    }

    private func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        monitor.stop()
        lastRunningState = false
        Log.app.debug("MeetingDetectionService — monitoring stopped")
    }

    // MARK: - Activity Handling

    /// Handles a change in input-device activity. Internal (not private) so unit
    /// tests can drive it directly.
    func handleActivityChange(_ running: Bool) {
        let wasRunning = lastRunningState
        lastRunningState = running

        // Only react to a rising edge (idle -> in use).
        guard running, !wasRunning else { return }

        // Respect the setting (it may have been disabled between events).
        guard settingsStore.meetingDetectionEnabled else { return }

        // Ignore activity caused by Wispr itself.
        guard !isSelfUsingMicrophone() else {
            Log.app.debug("MeetingDetectionService — activity is Wispr itself, ignoring")
            return
        }

        // Enforce the cooldown.
        if let last = lastNotificationDate, Date().timeIntervalSince(last) < cooldown {
            Log.app.debug("MeetingDetectionService — within cooldown, skipping notification")
            return
        }

        lastNotificationDate = Date()
        notifier.postMeetingDetectedNotification()
        Log.app.debug("MeetingDetectionService — meeting detected, notification posted")
    }
}
