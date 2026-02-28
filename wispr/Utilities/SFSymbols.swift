//
//  SFSymbols.swift
//  wispr
//
//  Centralized SF Symbol name constants used throughout the Wispr application.
//  Ensures visual consistency (Requirement 14.1) and makes symbol names easy
//  to update in one place.
//
//  Requirements: 14.1, 14.2
//

import Foundation

/// Centralized SF Symbol name constants for the Wispr application.
///
/// All SF Symbol names used in the app are defined here so they remain
/// consistent across views and are easy to audit or update.
///
/// Requirement 14.1: Use SF Symbols for all iconography throughout the app.
enum SFSymbols {

    // MARK: - Menu Bar States (Requirement 14.2)

    /// Menu bar icon for idle state.
    static let menuBarIdle = "microphone"

    /// Menu bar icon for recording state.
    static let menuBarRecording = "microphone.fill"

    /// Menu bar icon for processing state.
    static let menuBarProcessing = "waveform"

    /// Menu bar icon for error state.
    static let menuBarError = "exclamationmark.triangle"

    // MARK: - Recording Overlay

    /// Microphone icon shown during active recording.
    static let recordingMicrophone = "microphone.fill"

    /// Warning icon shown in error state overlay.
    static let overlayError = "exclamationmark.triangle.fill"

    // MARK: - Actions

    /// Settings / gear icon.
    static let settings = "gear"

    /// Quit / power icon.
    static let quit = "power"

    /// Download icon.
    static let download = "arrow.down.circle"

    /// Delete / trash icon.
    static let delete = "trash"

    /// Checkmark (filled circle) for success / active states.
    static let checkmark = "checkmark.circle.fill"

    /// Warning (filled triangle) for error labels.
    static let warning = "exclamationmark.triangle.fill"

    /// Microphone icon for general use.
    static let microphone = "microphone"

    /// Globe icon for language selection.
    static let language = "globe"

    /// CPU icon for model management.
    static let model = "cpu"

    /// Privacy / lock shield icon.
    static let privacy = "lock.shield"

    /// Accessibility icon.
    static let accessibility = "accessibility"

    /// Launch at login icon.
    static let launchAtLogin = "arrow.right.circle"

    // MARK: - Onboarding

    /// Welcome step icon.
    static let onboardingWelcome = "mic.badge.plus"

    /// Completion step icon.
    static let onboardingComplete = "checkmark.seal.fill"

    /// Test dictation step icon.
    static let onboardingTestDictation = "waveform"

    /// Back navigation chevron.
    static let chevronLeft = "chevron.left"

    /// Retry / refresh icon.
    static let retry = "arrow.clockwise"

    // MARK: - Settings View

    /// Keyboard icon for hotkey section.
    static let keyboard = "keyboard"

    /// Character bubble icon for language picker.
    static let characterBubble = "character.bubble"

    /// Pin icon for pinned language.
    static let pin = "pin"

    /// Recording indicator for hotkey recorder.
    static let recordCircle = "record.circle"
}
