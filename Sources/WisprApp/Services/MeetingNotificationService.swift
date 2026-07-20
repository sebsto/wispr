//
//  MeetingNotificationService.swift
//  wispr
//
//  Posts an actionable local notification when a meeting is detected and
//  routes the user's action back to the meeting transcription flow.
//

import Foundation
import UserNotifications
import WisprCore
import os

/// Abstraction over posting the "meeting detected" notification, so the
/// coordinating service can be unit-tested without the notification center.
@MainActor
protocol MeetingNotifying: AnyObject {
    /// Requests notification authorization (awaiting the user's response) and
    /// performs any one-time setup. Safe to call repeatedly.
    func requestAuthorization() async

    /// Posts the actionable "meeting detected" notification.
    func postMeetingDetectedNotification() async
}

/// Concrete `MeetingNotifying` backed by `UNUserNotificationCenter`.
///
/// Registers a single foreground action ("Start transcription"). When the user
/// activates the action — or taps the notification body — `onStartMeetingRequested`
/// is invoked on the main actor.
///
/// Setup (delegate + notification categories) is deferred until the first
/// `requestAuthorization()` call, so a disabled feature does no launch-time work
/// and does not claim the notification center's single delegate slot.
@MainActor
final class MeetingNotificationService: NSObject, MeetingNotifying,
    UNUserNotificationCenterDelegate
{

    nonisolated static let categoryIdentifier = "com.stormacq.mac.wispr.meeting-detected"
    nonisolated static let startActionIdentifier = "START_MEETING_TRANSCRIPTION"
    nonisolated static let notificationIdentifier =
        "com.stormacq.mac.wispr.meeting-detected.notification"

    /// Invoked on the main actor when the user asks to start transcription.
    var onStartMeetingRequested: (@MainActor () -> Void)?

    private let center = UNUserNotificationCenter.current()

    /// Whether the delegate and notification categories have been registered.
    private var isConfigured = false

    // MARK: - MeetingNotifying

    func requestAuthorization() async {
        configureIfNeeded()
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            Log.app.debug("MeetingNotificationService — authorization granted: \(granted)")
        } catch {
            Log.app.error(
                "MeetingNotificationService — authorization error: \(error.localizedDescription)")
        }
    }

    func postMeetingDetectedNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Meeting detected"
        content.body = "Start transcribing this meeting with Wispr?"
        content.categoryIdentifier = Self.categoryIdentifier
        content.sound = .default

        // Fixed identifier so a pending/duplicate notification coalesces rather
        // than stacking up.
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil)

        do {
            try await center.add(request)
        } catch {
            Log.app.error(
                "MeetingNotificationService — failed to post notification: \(error.localizedDescription)"
            )
        }
    }

    // MARK: - One-time Setup

    /// Registers the delegate and notification category the first time the
    /// feature is enabled. Idempotent.
    private func configureIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true
        center.delegate = self
        registerCategory()
    }

    private func registerCategory() {
        let startAction = UNNotificationAction(
            identifier: Self.startActionIdentifier,
            title: "Start transcription",
            options: [.foreground])

        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [startAction],
            intentIdentifiers: [],
            options: [])

        center.setNotificationCategories([category])
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the banner even though a menu-bar (accessory) app is effectively
    /// always frontmost.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Route the "Start transcription" action (or a tap on the notification) to
    /// the meeting flow.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let action = response.actionIdentifier
        guard action == Self.startActionIdentifier
            || action == UNNotificationDefaultActionIdentifier
        else { return }

        await MainActor.run { [weak self] in
            self?.onStartMeetingRequested?()
        }
    }
}
