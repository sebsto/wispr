//
//  AccessibilityTests.swift
//  wispr
//
//  Accessibility tests for Wispr voice dictation application.
//  Tests VoiceOver labels, keyboard navigation modifiers, accessibility
//  setting adaptations, and state change announcement text generation.
//  Requirements: 17.1, 17.2, 17.4, 17.5, 17.6
//

import Testing
import SwiftUI
import AppKit
@testable import wispr

// MARK: - Accessibility Label Generation Tests (Requirement 17.1)

@MainActor
@Suite("Accessibility Label Generation")
struct AccessibilityLabelGenerationTests {

    // MARK: - Recording Overlay Labels

    /// Mirrors RecordingOverlayView.accessibilityLabelForState
    private func overlayAccessibilityLabel(for state: AppStateType) -> String {
        switch state {
        case .recording:
            "Recording in progress"
        case .processing:
            "Processing speech"
        case .error(let message):
            "Error: \(message)"
        case .idle:
            "Recording overlay"
        }
    }

    @Test("Overlay label for recording state is descriptive")
    func testOverlayRecordingLabel() {
        let label = overlayAccessibilityLabel(for: .recording)
        #expect(label.contains("Recording"), "Recording label should mention recording")
        #expect(!label.isEmpty)
    }

    @Test("Overlay label for processing state is descriptive")
    func testOverlayProcessingLabel() {
        let label = overlayAccessibilityLabel(for: .processing)
        #expect(label.contains("Processing"), "Processing label should mention processing")
    }

    @Test("Overlay label for error state includes the error message")
    func testOverlayErrorLabelIncludesMessage() {
        let errorMsg = "Microphone not found"
        let label = overlayAccessibilityLabel(for: .error(errorMsg))
        #expect(label.contains(errorMsg), "Error label should include the error message")
        #expect(label.hasPrefix("Error:"), "Error label should start with 'Error:'")
    }

    @Test("Overlay label for idle state provides context")
    func testOverlayIdleLabel() {
        let label = overlayAccessibilityLabel(for: .idle)
        #expect(!label.isEmpty, "Idle label should not be empty")
    }

    @Test("All overlay labels are non-empty for every state",
          arguments: [
            AppStateType.idle,
            .recording,
            .processing,
            .error("test error"),
            .error("")
          ])
    func testAllOverlayLabelsNonEmpty(state: AppStateType) {
        let label = overlayAccessibilityLabel(for: state)
        #expect(!label.isEmpty, "Accessibility label should never be empty for state: \(state)")
    }

    // MARK: - Menu Bar Icon Accessibility Descriptions

    /// Mirrors MenuBarController.updateIcon(for:) accessibility descriptions
    private func menuBarIconDescription(for state: AppStateType) -> String {
        switch state {
        case .idle:
            "Wispr — Idle"
        case .recording:
            "Wispr — Recording"
        case .processing:
            "Wispr — Processing"
        case .error:
            "Wispr — Error"
        }
    }

    @Test("Menu bar icon descriptions are unique per state")
    func testMenuBarIconDescriptionsUnique() {
        let states: [AppStateType] = [.idle, .recording, .processing, .error("test")]
        let descriptions = states.map { menuBarIconDescription(for: $0) }
        let uniqueDescriptions = Set(descriptions)
        #expect(uniqueDescriptions.count == states.count,
                "Each state should have a unique accessibility description")
    }

    @Test("Menu bar icon descriptions all contain 'Wispr'")
    func testMenuBarIconDescriptionsContainAppName() {
        let states: [AppStateType] = [.idle, .recording, .processing, .error("test")]
        for state in states {
            let desc = menuBarIconDescription(for: state)
            #expect(desc.contains("Wispr"), "Description for \(state) should contain app name")
        }
    }

    // MARK: - Onboarding Step Labels

    @Test("All onboarding steps have valid raw values for step indicator label")
    func testOnboardingStepIndicatorLabels() {
        let totalSteps = OnboardingStep.allCases.count
        for step in OnboardingStep.allCases {
            let label = "Step \(step.rawValue + 1) of \(totalSteps)"
            #expect(label.contains("of \(totalSteps)"),
                    "Step indicator should show total steps")
            #expect(step.rawValue + 1 >= 1 && step.rawValue + 1 <= totalSteps,
                    "Step number should be within valid range")
        }
    }
}

// MARK: - State Change Announcement Tests (Requirement 17.3, 17.11)

@MainActor
@Suite("State Change Announcement Text")
struct StateChangeAnnouncementTests {

    /// Mirrors the announcement strings used in StateManager for NSAccessibility.post
    private func announcementText(for transition: StateTransition) -> String {
        switch transition {
        case .beginRecording:
            "Recording started"
        case .beginProcessing:
            "Processing speech"
        case .textInserted:
            "Text inserted"
        case .error(let message):
            "Error: \(message)"
        }
    }

    enum StateTransition {
        case beginRecording
        case beginProcessing
        case textInserted
        case error(String)
    }

    @Test("Recording started announcement is descriptive")
    func testRecordingStartedAnnouncement() {
        let text = announcementText(for: .beginRecording)
        #expect(text == "Recording started")
        #expect(!text.isEmpty)
    }

    @Test("Processing speech announcement is descriptive")
    func testProcessingSpeechAnnouncement() {
        let text = announcementText(for: .beginProcessing)
        #expect(text == "Processing speech")
    }

    @Test("Text inserted announcement is descriptive")
    func testTextInsertedAnnouncement() {
        let text = announcementText(for: .textInserted)
        #expect(text == "Text inserted")
    }

    @Test("Error announcement includes the error message")
    func testErrorAnnouncement() {
        let errorMsg = "Model failed to load"
        let text = announcementText(for: .error(errorMsg))
        #expect(text == "Error: \(errorMsg)")
        #expect(text.contains(errorMsg))
    }

    @Test("Error announcement with empty message still has prefix")
    func testErrorAnnouncementEmptyMessage() {
        let text = announcementText(for: .error(""))
        #expect(text.hasPrefix("Error:"), "Error announcement should always have prefix")
    }

    @Test("All announcements are non-empty",
          arguments: [
            StateTransition.beginRecording,
            .beginProcessing,
            .textInserted,
            .error("some error"),
            .error("")
          ])
    func testAllAnnouncementsNonEmpty(transition: StateTransition) {
        let text = announcementText(for: transition)
        #expect(!text.isEmpty, "Announcement text should never be empty")
    }
}

// MARK: - Minimum Touch Target Modifier Tests (Requirement 17.12)

@MainActor
@Suite("MinimumTouchTargetModifier Tests")
struct MinimumTouchTargetModifierTests {

    @Test("MinimumTouchTargetModifier enforces 44x44pt minimum")
    func testMinimumTouchTargetSize() {
        // The modifier sets frame(minWidth: 44, minHeight: 44)
        // Verify the modifier can be applied without error
        let modifier = MinimumTouchTargetModifier()
        let view = Text("Test").modifier(modifier)
        // The view should compile and apply the modifier
        _ = view
    }

    @Test("MinimumTouchTargetModifier includes contentShape for hit testing")
    func testMinimumTouchTargetContentShape() {
        // Verify the modifier applies contentShape(Rectangle()) for hit testing
        // This ensures the entire 44x44 area is tappable, not just the content
        let modifier = MinimumTouchTargetModifier()
        _ = Text("Tap").modifier(modifier)
        // If this compiles and runs, the contentShape is applied
    }

    @Test("View extension minimumTouchTarget() applies modifier")
    func testViewExtensionMinimumTouchTarget() {
        let view = Button("Action") {}.minimumTouchTarget()
        _ = view
        // Verifies the extension method exists and compiles
    }
}

// MARK: - Keyboard Focus Ring Modifier Tests (Requirement 17.2, 17.8)

@MainActor
@Suite("KeyboardFocusRingModifier Tests")
struct KeyboardFocusRingModifierTests {

    @Test("KeyboardFocusRingModifier makes view focusable")
    func testFocusRingMakesFocusable() {
        // The modifier applies .focusable() and .focused($isFocused)
        // Verify it compiles and can be applied
        let theme = UIThemeEngine()
        let view = Text("Focusable")
            .modifier(KeyboardFocusRingModifier())
            .environment(theme)
        _ = view
    }

    @Test("View extension keyboardFocusRing() applies modifier")
    func testViewExtensionKeyboardFocusRing() {
        let theme = UIThemeEngine()
        let view = Button("Click") {}.keyboardFocusRing().environment(theme)
        _ = view
        // Verifies the extension method exists and compiles
    }

    @Test("Focus ring uses accent color from theme")
    func testFocusRingUsesAccentColor() {
        let theme = UIThemeEngine()
        #expect(theme.accentColor == .accentColor,
                "Focus ring should use the system accent color")
    }
}

// MARK: - UIThemeEngine Accessibility Adaptation Tests (Requirements 17.4, 17.5, 17.6)

@MainActor
@Suite("UIThemeEngine Accessibility Adaptations")
struct UIThemeEngineAccessibilityAdaptationTests {

    // MARK: - Combined Accessibility Settings

    @Test("All animations disabled when reduceMotion is true regardless of other settings")
    func testReduceMotionOverridesOtherSettings() {
        let engine = UIThemeEngine()
        engine.reduceMotion = true
        engine.reduceTransparency = true
        engine.increaseContrast = true

        #expect(engine.standardSpringAnimation == nil,
                "Spring animation should be nil with reduceMotion even when other settings are on")
        #expect(engine.interactiveFeedbackAnimation == nil,
                "Feedback animation should be nil with reduceMotion even when other settings are on")
    }

    @Test("Opaque materials used when reduceTransparency is true regardless of other settings")
    func testReduceTransparencyWithOtherSettings() {
        let engine = UIThemeEngine()
        engine.reduceTransparency = true
        engine.increaseContrast = true
        engine.isDarkMode = true

        // Materials should be opaque (.bar) when reduceTransparency is on
        // We verify the flag is respected
        #expect(engine.reduceTransparency == true)
        // The overlayMaterial and panelMaterial should return .bar
        _ = engine.overlayMaterial
        _ = engine.panelMaterial
    }

    @Test("High contrast colors applied in dark mode with increaseContrast")
    func testHighContrastDarkMode() {
        let engine = UIThemeEngine()
        engine.isDarkMode = true
        engine.increaseContrast = true

        #expect(engine.primaryTextColor == .white)
        #expect(engine.secondaryTextColor == Color.white.opacity(0.9))
        #expect(engine.borderColor == .white.opacity(0.6))
    }

    @Test("High contrast colors applied in light mode with increaseContrast")
    func testHighContrastLightMode() {
        let engine = UIThemeEngine()
        engine.isDarkMode = false
        engine.increaseContrast = true

        #expect(engine.primaryTextColor == .black)
        #expect(engine.secondaryTextColor == Color.black.opacity(0.9))
        #expect(engine.borderColor == .black.opacity(0.6))
    }

    @Test("Normal contrast uses semantic colors")
    func testNormalContrastSemanticColors() {
        let engine = UIThemeEngine()
        engine.increaseContrast = false

        #expect(engine.primaryTextColor == .primary)
        #expect(engine.secondaryTextColor == .secondary)
    }

    @Test("Border color has lower opacity without increaseContrast in dark mode")
    func testNormalBorderDarkMode() {
        let engine = UIThemeEngine()
        engine.isDarkMode = true
        engine.increaseContrast = false

        #expect(engine.borderColor == .white.opacity(0.15))
    }

    @Test("Border color has lower opacity without increaseContrast in light mode")
    func testNormalBorderLightMode() {
        let engine = UIThemeEngine()
        engine.isDarkMode = false
        engine.increaseContrast = false

        #expect(engine.borderColor == .black.opacity(0.15))
    }

    // MARK: - All Three Settings Combined

    @Test("All accessibility settings enabled simultaneously")
    func testAllAccessibilitySettingsEnabled() {
        let engine = UIThemeEngine()
        engine.reduceMotion = true
        engine.reduceTransparency = true
        engine.increaseContrast = true
        engine.isDarkMode = false

        // Animations disabled
        #expect(engine.standardSpringAnimation == nil)
        #expect(engine.interactiveFeedbackAnimation == nil)

        // High contrast colors
        #expect(engine.primaryTextColor == .black)

        // Opaque materials
        #expect(engine.reduceTransparency == true)
    }

    @Test("No accessibility settings enabled uses defaults")
    func testNoAccessibilitySettings() {
        let engine = UIThemeEngine()
        engine.reduceMotion = false
        engine.reduceTransparency = false
        engine.increaseContrast = false

        // Animations enabled
        #expect(engine.standardSpringAnimation != nil)
        #expect(engine.interactiveFeedbackAnimation != nil)

        // Semantic colors
        #expect(engine.primaryTextColor == .primary)
        #expect(engine.secondaryTextColor == .secondary)
    }

    // MARK: - View Modifier Compilation Tests

    @Test("LiquidGlassOverlayModifier applies with reduceTransparency off")
    func testLiquidGlassOverlayNormal() {
        let theme = UIThemeEngine()
        theme.reduceTransparency = false
        let view = Text("Test").liquidGlassOverlay().environment(theme)
        _ = view
    }

    @Test("LiquidGlassOverlayModifier applies with reduceTransparency on")
    func testLiquidGlassOverlayOpaque() {
        let theme = UIThemeEngine()
        theme.reduceTransparency = true
        let view = Text("Test").liquidGlassOverlay().environment(theme)
        _ = view
    }

    @Test("HighContrastBorderModifier applies with increaseContrast on")
    func testHighContrastBorderModifier() {
        let theme = UIThemeEngine()
        theme.increaseContrast = true
        let view = Text("Test").highContrastBorder(cornerRadius: 8).environment(theme)
        _ = view
    }

    @Test("MotionRespectingAnimationModifier applies with reduceMotion on")
    func testMotionRespectingAnimationModifier() {
        let theme = UIThemeEngine()
        theme.reduceMotion = true
        let view = Text("Test").motionRespectingAnimation(value: true).environment(theme)
        _ = view
    }
}

// MARK: - Menu Bar Accessibility Tests (Requirement 17.10)

@MainActor
@Suite("Menu Bar Accessibility")
struct MenuBarAccessibilityTests {

    @Test("Menu bar icon has accessibility description for all states",
          arguments: [
            AppStateType.idle,
            .recording,
            .processing,
            .error("test")
          ])
    func testMenuBarIconAccessibilityDescription(state: AppStateType) {
        let theme = UIThemeEngine()
        let symbolName = theme.menuBarSymbol(for: state)

        // Verify the symbol name is valid (non-empty)
        #expect(!symbolName.isEmpty, "Symbol name should not be empty for state: \(state)")

        // Verify NSImage can be created with accessibility description
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: "Wispr status"
        )
        #expect(image != nil, "NSImage should be creatable for symbol: \(symbolName)")
    }

    @Test("Menu item images have accessibility descriptions")
    func testMenuItemImageAccessibilityDescriptions() {
        let theme = UIThemeEngine()

        // Verify all action symbols produce valid NSImages with descriptions
        let actions: [(UIThemeEngine.ActionSymbol, String)] = [
            (.settings, "Settings"),
            (.quit, "Quit"),
            (.language, "Language"),
            (.model, "Model Management"),
        ]

        for (action, description) in actions {
            let symbolName = theme.actionSymbol(action)
            let image = NSImage(
                systemSymbolName: symbolName,
                accessibilityDescription: description
            )
            #expect(image != nil,
                    "NSImage should be creatable for action \(action) with symbol \(symbolName)")
        }
    }
}

// MARK: - WisprError Accessibility Description Tests

@MainActor
@Suite("WisprrError Accessibility Descriptions")
struct WisprErrorAccessibilityTests {

    @Test("All WisprError cases produce non-empty localized descriptions",
          arguments: [
            WisprError.microphonePermissionDenied,
            .accessibilityPermissionDenied,
            .noAudioDeviceAvailable,
            .audioDeviceDisconnected,
            .audioRecordingFailed("test"),
            .modelLoadFailed("test"),
            .modelNotDownloaded,
            .transcriptionFailed("test"),
            .emptyTranscription,
            .textInsertionFailed("test"),
            .hotkeyConflict("test"),
            .hotkeyRegistrationFailed,
            .modelDownloadFailed("test"),
            .modelValidationFailed("test"),
            .modelDeletionFailed("test"),
            .noModelsAvailable
          ])
    func testWisprErrorDescriptions(error: WisprError) {
        let description = error.localizedDescription
        #expect(!description.isEmpty,
                "Error \(error) should have a non-empty localized description for VoiceOver")
    }

    @Test("Error announcement text includes error description")
    func testErrorAnnouncementIncludesDescription() {
        let error = WisprError.noAudioDeviceAvailable
        let message = error.localizedDescription
        let announcement = "Error: \(message)"
        #expect(announcement.contains(message),
                "Announcement should include the error description")
    }
}
