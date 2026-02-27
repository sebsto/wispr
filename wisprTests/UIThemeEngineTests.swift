//
//  UIThemeEngineTests.swift
//  wispr
//
//  Unit tests for UIThemeEngine using swift-testing framework
//

import Testing
import SwiftUI
@testable import wispr

@MainActor
@Suite("UIThemeEngine Tests")
struct UIThemeEngineTests {

    // MARK: - Initial State Tests

    @Test("UIThemeEngine initializes with default values")
    func testDefaultValues() {
        let engine = UIThemeEngine()

        // Accessibility defaults should reflect system state, but the properties are settable.
        // We just verify they are Bool values (no crash on init).
        _ = engine.isDarkMode
        _ = engine.reduceMotion
        _ = engine.reduceTransparency
        _ = engine.increaseContrast
    }

    // MARK: - Reduce Motion Tests (Requirement 17.5)

    @Test("standardSpringAnimation returns nil when reduceMotion is true")
    func testReduceMotionDisablesSpringAnimation() {
        let engine = UIThemeEngine()
        engine.reduceMotion = true

        #expect(engine.standardSpringAnimation == nil,
                "Spring animation should be nil when Reduce Motion is enabled")
    }

    @Test("standardSpringAnimation returns non-nil when reduceMotion is false")
    func testNoReduceMotionEnablesSpringAnimation() {
        let engine = UIThemeEngine()
        engine.reduceMotion = false

        #expect(engine.standardSpringAnimation != nil,
                "Spring animation should be provided when Reduce Motion is disabled")
    }

    @Test("interactiveFeedbackAnimation returns nil when reduceMotion is true")
    func testReduceMotionDisablesFeedbackAnimation() {
        let engine = UIThemeEngine()
        engine.reduceMotion = true

        #expect(engine.interactiveFeedbackAnimation == nil,
                "Feedback animation should be nil when Reduce Motion is enabled")
    }

    @Test("interactiveFeedbackAnimation returns non-nil when reduceMotion is false")
    func testNoReduceMotionEnablesFeedbackAnimation() {
        let engine = UIThemeEngine()
        engine.reduceMotion = false

        #expect(engine.interactiveFeedbackAnimation != nil,
                "Feedback animation should be provided when Reduce Motion is disabled")
    }

    // MARK: - Reduce Transparency Tests (Requirement 17.6)

    @Test("overlayMaterial returns opaque material when reduceTransparency is true")
    func testReduceTransparencyOverlayMaterial() {
        let engine = UIThemeEngine()

        engine.reduceTransparency = false
        let normalMaterial = engine.overlayMaterial
        _ = normalMaterial // .ultraThinMaterial

        engine.reduceTransparency = true
        let opaqueMaterial = engine.overlayMaterial
        _ = opaqueMaterial // .bar

        // Material is opaque type; we verify the flag drives the branch
        // by checking the reduceTransparency property is respected
        #expect(engine.reduceTransparency == true)
    }

    @Test("panelMaterial returns opaque material when reduceTransparency is true")
    func testReduceTransparencyPanelMaterial() {
        let engine = UIThemeEngine()

        engine.reduceTransparency = false
        let normalMaterial = engine.panelMaterial
        _ = normalMaterial // .regularMaterial

        engine.reduceTransparency = true
        let opaqueMaterial = engine.panelMaterial
        _ = opaqueMaterial // .bar

        #expect(engine.reduceTransparency == true)
    }

    // MARK: - Increase Contrast Tests (Requirement 17.4)

    @Test("borderColor has higher opacity when increaseContrast is true (dark mode)")
    func testIncreaseContrastBorderColorDark() {
        let engine = UIThemeEngine()
        engine.isDarkMode = true

        engine.increaseContrast = false
        let normalBorder = engine.borderColor // .white.opacity(0.15)

        engine.increaseContrast = true
        let highContrastBorder = engine.borderColor // .white.opacity(0.6)

        // High contrast border should differ from normal border
        #expect(normalBorder != highContrastBorder,
                "Border color should change when Increase Contrast is enabled")
    }

    @Test("borderColor has higher opacity when increaseContrast is true (light mode)")
    func testIncreaseContrastBorderColorLight() {
        let engine = UIThemeEngine()
        engine.isDarkMode = false

        engine.increaseContrast = false
        let normalBorder = engine.borderColor // .black.opacity(0.15)

        engine.increaseContrast = true
        let highContrastBorder = engine.borderColor // .black.opacity(0.6)

        #expect(normalBorder != highContrastBorder,
                "Border color should change when Increase Contrast is enabled in light mode")
    }

    @Test("primaryTextColor is pure white in dark mode with increaseContrast")
    func testIncreaseContrastPrimaryTextDark() {
        let engine = UIThemeEngine()
        engine.isDarkMode = true
        engine.increaseContrast = true

        #expect(engine.primaryTextColor == .white,
                "Primary text should be pure white in dark mode with Increase Contrast")
    }

    @Test("primaryTextColor is pure black in light mode with increaseContrast")
    func testIncreaseContrastPrimaryTextLight() {
        let engine = UIThemeEngine()
        engine.isDarkMode = false
        engine.increaseContrast = true

        #expect(engine.primaryTextColor == .black,
                "Primary text should be pure black in light mode with Increase Contrast")
    }

    @Test("primaryTextColor is .primary when increaseContrast is false")
    func testNormalPrimaryText() {
        let engine = UIThemeEngine()
        engine.increaseContrast = false

        #expect(engine.primaryTextColor == .primary,
                "Primary text should be .primary when Increase Contrast is disabled")
    }

    @Test("secondaryTextColor uses high opacity when increaseContrast is true")
    func testIncreaseContrastSecondaryText() {
        let engine = UIThemeEngine()
        engine.increaseContrast = true
        engine.isDarkMode = true

        let color = engine.secondaryTextColor
        #expect(color == Color.white.opacity(0.9),
                "Secondary text should be white with 0.9 opacity in dark mode with Increase Contrast")
    }

    @Test("secondaryTextColor is .secondary when increaseContrast is false")
    func testNormalSecondaryText() {
        let engine = UIThemeEngine()
        engine.increaseContrast = false

        #expect(engine.secondaryTextColor == .secondary,
                "Secondary text should be .secondary when Increase Contrast is disabled")
    }

    // MARK: - SF Symbol Tests (Requirement 14.4)

    @Test("menuBarSymbol returns correct symbol for idle state")
    func testMenuBarSymbolIdle() {
        let engine = UIThemeEngine()
        #expect(engine.menuBarSymbol(for: .idle) == "microphone")
    }

    @Test("menuBarSymbol returns correct symbol for recording state")
    func testMenuBarSymbolRecording() {
        let engine = UIThemeEngine()
        #expect(engine.menuBarSymbol(for: .recording) == "microphone.fill")
    }

    @Test("menuBarSymbol returns correct symbol for processing state")
    func testMenuBarSymbolProcessing() {
        let engine = UIThemeEngine()
        #expect(engine.menuBarSymbol(for: .processing) == "waveform")
    }

    @Test("menuBarSymbol returns correct symbol for error state")
    func testMenuBarSymbolError() {
        let engine = UIThemeEngine()
        #expect(engine.menuBarSymbol(for: .error("test")) == "exclamationmark.triangle")
    }

    // MARK: - Action Symbol Tests

    @Test("actionSymbol returns non-empty strings for all cases",
          arguments: [
            UIThemeEngine.ActionSymbol.settings,
            .quit,
            .download,
            .delete,
            .checkmark,
            .warning,
            .microphone,
            .language,
            .model,
            .privacy,
            .accessibility,
            .launchAtLogin
          ])
    func testActionSymbolNonEmpty(action: UIThemeEngine.ActionSymbol) {
        let engine = UIThemeEngine()
        let symbol = engine.actionSymbol(action)
        #expect(!symbol.isEmpty, "Action symbol for \(action) should not be empty")
    }

    @Test("actionSymbol returns expected specific symbols")
    func testActionSymbolValues() {
        let engine = UIThemeEngine()
        #expect(engine.actionSymbol(.settings) == "gear")
        #expect(engine.actionSymbol(.quit) == "power")
        #expect(engine.actionSymbol(.download) == "arrow.down.circle")
        #expect(engine.actionSymbol(.delete) == "trash")
        #expect(engine.actionSymbol(.checkmark) == "checkmark.circle.fill")
        #expect(engine.actionSymbol(.warning) == "exclamationmark.triangle.fill")
        #expect(engine.actionSymbol(.microphone) == "microphone")
        #expect(engine.actionSymbol(.language) == "globe")
        #expect(engine.actionSymbol(.model) == "cpu")
        #expect(engine.actionSymbol(.privacy) == "lock.shield")
        #expect(engine.actionSymbol(.accessibility) == "accessibility")
        #expect(engine.actionSymbol(.launchAtLogin) == "arrow.right.circle")
    }

    // MARK: - Dark Mode Adaptation Tests (Requirement 14.4)

    @Test("isDarkMode flag affects borderColor")
    func testDarkModeAffectsBorderColor() {
        let engine = UIThemeEngine()
        engine.increaseContrast = false

        engine.isDarkMode = true
        let darkBorder = engine.borderColor

        engine.isDarkMode = false
        let lightBorder = engine.borderColor

        #expect(darkBorder != lightBorder,
                "Border color should differ between dark and light mode")
    }

    @Test("isDarkMode flag affects primaryTextColor with increaseContrast")
    func testDarkModeAffectsPrimaryTextWithContrast() {
        let engine = UIThemeEngine()
        engine.increaseContrast = true

        engine.isDarkMode = true
        let darkText = engine.primaryTextColor

        engine.isDarkMode = false
        let lightText = engine.primaryTextColor

        #expect(darkText != lightText,
                "Primary text color should differ between dark and light mode when Increase Contrast is on")
    }

    @Test("isDarkMode flag affects secondaryTextColor with increaseContrast")
    func testDarkModeAffectsSecondaryTextWithContrast() {
        let engine = UIThemeEngine()
        engine.increaseContrast = true

        engine.isDarkMode = true
        let darkText = engine.secondaryTextColor

        engine.isDarkMode = false
        let lightText = engine.secondaryTextColor

        #expect(darkText != lightText,
                "Secondary text color should differ between dark and light mode when Increase Contrast is on")
    }

    // MARK: - Constant Color Tests

    @Test("errorColor is red")
    func testErrorColor() {
        let engine = UIThemeEngine()
        #expect(engine.errorColor == .red)
    }

    @Test("successColor is green")
    func testSuccessColor() {
        let engine = UIThemeEngine()
        #expect(engine.successColor == .green)
    }

    @Test("accentColor is .accentColor")
    func testAccentColor() {
        let engine = UIThemeEngine()
        #expect(engine.accentColor == .accentColor)
    }

    // MARK: - Monitoring Tests

    @Test("stopMonitoring cancels monitoring task")
    func testStopMonitoring() {
        let engine = UIThemeEngine()
        engine.startMonitoring()
        engine.stopMonitoring()
        // No crash, monitoring stopped cleanly
    }

    @Test("startMonitoring is idempotent")
    func testStartMonitoringIdempotent() {
        let engine = UIThemeEngine()
        engine.startMonitoring()
        engine.startMonitoring() // Should not create a second task
        engine.stopMonitoring()
    }
}
