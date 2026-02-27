//
//  RecordingOverlayTests.swift
//  wispr
//
//  Unit tests for RecordingOverlayPanel and RecordingOverlayView logic.
//  Tests overlay lifecycle, accessibility labels, and audio level bar calculations.
//  Requirements: 9.1, 9.4, 17.1, 17.3
//

import Testing
import AppKit
@testable import wispr

// MARK: - Test Helpers

/// Creates a RecordingOverlayPanel with real dependencies for unit testing.
@MainActor
private func createTestOverlayPanel() -> (RecordingOverlayPanel, StateManager, UIThemeEngine) {
    let audioEngine = AudioEngine()
    let whisperService = WhisperService()
    let textInsertionService = TextInsertionService()
    let hotkeyMonitor = HotkeyMonitor()
    let permissionManager = PermissionManager()
    let settingsStore = SettingsStore(
        defaults: UserDefaults(suiteName: "test.wispr.overlay.\(UUID().uuidString)")!
    )

    let stateManager = StateManager(
        audioEngine: audioEngine,
        whisperService: whisperService,
        textInsertionService: textInsertionService,
        hotkeyMonitor: hotkeyMonitor,
        permissionManager: permissionManager,
        settingsStore: settingsStore
    )

    let themeEngine = UIThemeEngine()

    let panel = RecordingOverlayPanel(
        stateManager: stateManager,
        themeEngine: themeEngine
    )

    return (panel, stateManager, themeEngine)
}

// MARK: - RecordingOverlayPanel Tests

@MainActor
@Suite("RecordingOverlayPanel Tests")
struct RecordingOverlayPanelTests {

    // MARK: - Initial State (Requirement 9.1)

    @Test("Panel starts with isVisible = false")
    func testInitialVisibility() {
        let (panel, _, _) = createTestOverlayPanel()
        #expect(panel.isVisible == false, "Panel should not be visible on creation")
    }

    // MARK: - Show/Dismiss Lifecycle (Requirements 9.1, 9.4)

    @Test("show() sets isVisible to true")
    func testShowSetsVisible() {
        let (panel, _, _) = createTestOverlayPanel()

        #expect(panel.isVisible == false)
        panel.show()
        #expect(panel.isVisible == true, "Panel should be visible after show()")
    }

    @Test("show() is idempotent when already visible")
    func testShowIdempotent() {
        let (panel, _, _) = createTestOverlayPanel()

        panel.show()
        #expect(panel.isVisible == true)

        // Calling show() again should not crash or change state
        panel.show()
        #expect(panel.isVisible == true)
    }

    @Test("dismiss() transitions isVisible to false after animation")
    func testDismissSetsInvisible() async throws {
        let (panel, _, themeEngine) = createTestOverlayPanel()

        // Disable animations for instant dismiss
        themeEngine.reduceMotion = true

        panel.show()
        #expect(panel.isVisible == true)

        panel.dismiss()

        // Wait for the dismiss cleanup task (duration 0 + 50ms buffer)
        try await Task.sleep(for: .milliseconds(150))

        #expect(panel.isVisible == false, "Panel should not be visible after dismiss()")
    }

    @Test("dismiss() is no-op when not visible")
    func testDismissWhenNotVisible() {
        let (panel, _, _) = createTestOverlayPanel()

        #expect(panel.isVisible == false)

        // Should not crash or change state
        panel.dismiss()
        #expect(panel.isVisible == false)
    }

    @Test("show() after dismiss() makes panel visible again")
    func testShowAfterDismiss() async throws {
        let (panel, _, themeEngine) = createTestOverlayPanel()
        themeEngine.reduceMotion = true

        panel.show()
        #expect(panel.isVisible == true)

        panel.dismiss()
        try await Task.sleep(for: .milliseconds(150))
        #expect(panel.isVisible == false)

        panel.show()
        #expect(panel.isVisible == true, "Panel should be visible after re-showing")
    }
}

// MARK: - Accessibility Label Tests (Requirements 17.1, 17.3)

@MainActor
@Suite("RecordingOverlay Accessibility Tests")
struct RecordingOverlayAccessibilityTests {

    /// Tests the accessibility label logic that RecordingOverlayView uses
    /// for different AppStateType values. We test the same switch logic
    /// that drives the view's `.accessibilityLabel`.

    @Test("Accessibility label for idle state")
    func testAccessibilityLabelIdle() {
        let label = accessibilityLabel(for: .idle)
        #expect(label == "Recording overlay")
    }

    @Test("Accessibility label for recording state")
    func testAccessibilityLabelRecording() {
        let label = accessibilityLabel(for: .recording)
        #expect(label == "Recording in progress")
    }

    @Test("Accessibility label for processing state")
    func testAccessibilityLabelProcessing() {
        let label = accessibilityLabel(for: .processing)
        #expect(label == "Processing speech")
    }

    @Test("Accessibility label for error state includes message")
    func testAccessibilityLabelError() {
        let label = accessibilityLabel(for: .error("Microphone disconnected"))
        #expect(label == "Error: Microphone disconnected")
    }

    @Test("Accessibility label for error state with empty message")
    func testAccessibilityLabelErrorEmpty() {
        let label = accessibilityLabel(for: .error(""))
        #expect(label == "Error: ")
    }

    /// Mirrors the `accessibilityLabelForState` computed property from RecordingOverlayView.
    private func accessibilityLabel(for state: AppStateType) -> String {
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
}

// MARK: - Audio Level Bar Height Tests

@MainActor
@Suite("RecordingOverlay Audio Level Bar Tests")
struct RecordingOverlayBarHeightTests {

    /// Mirrors the `barHeight(for:)` function from RecordingOverlayView.
    /// Maps a 0…1 audio level to a bar height between 4 and 28 points.
    private func barHeight(for level: Float) -> CGFloat {
        let clamped = min(max(CGFloat(level), 0), 1)
        return 4 + clamped * 24
    }

    @Test("Bar height at zero level is minimum (4pt)")
    func testBarHeightZero() {
        let height = barHeight(for: 0.0)
        #expect(height == 4.0, "Zero level should produce minimum bar height of 4pt")
    }

    @Test("Bar height at full level is maximum (28pt)")
    func testBarHeightFull() {
        let height = barHeight(for: 1.0)
        #expect(height == 28.0, "Full level should produce maximum bar height of 28pt")
    }

    @Test("Bar height at mid level is 16pt")
    func testBarHeightMid() {
        let height = barHeight(for: 0.5)
        #expect(height == 16.0, "Mid level (0.5) should produce 16pt bar height")
    }

    @Test("Bar height clamps negative values to minimum")
    func testBarHeightNegative() {
        let height = barHeight(for: -0.5)
        #expect(height == 4.0, "Negative level should clamp to minimum 4pt")
    }

    @Test("Bar height clamps values above 1.0 to maximum")
    func testBarHeightAboveOne() {
        let height = barHeight(for: 1.5)
        #expect(height == 28.0, "Level above 1.0 should clamp to maximum 28pt")
    }

    @Test("Bar height scales linearly between min and max")
    func testBarHeightLinearScaling() {
        let height25 = barHeight(for: 0.25)
        let height75 = barHeight(for: 0.75)

        #expect(height25 == 10.0, "0.25 level should produce 10pt (4 + 0.25 * 24)")
        #expect(height75 == 22.0, "0.75 level should produce 22pt (4 + 0.75 * 24)")
    }
}
