import SwiftUI
import Observation
import AppKit

/// Manages visual theming for the Wisp application including Liquid Glass materials,
/// semantic colors, SF Symbols, system appearance detection, and accessibility adaptations.
///
/// UIThemeEngine is the single source of truth for all visual styling decisions.
/// It detects system appearance changes (light/dark mode) and accessibility settings
/// (Reduce Motion, Reduce Transparency, Increase Contrast), exposing reactive properties
/// that SwiftUI views can observe to adapt their presentation.
@MainActor
@Observable
final class UIThemeEngine {

    // MARK: - Shared Instance

    static let shared = UIThemeEngine()

    // MARK: - System Appearance

    /// Whether the system is currently in dark mode
    var isDarkMode: Bool = false

    // MARK: - Accessibility Settings

    /// Whether the user has enabled Reduce Motion in System Settings
    var reduceMotion: Bool = false

    /// Whether the user has enabled Reduce Transparency in System Settings
    var reduceTransparency: Bool = false

    /// Whether the user has enabled Increase Contrast in System Settings
    var increaseContrast: Bool = false

    // MARK: - Private State

    /// Task monitoring system appearance changes via KVO
    private var appearanceTask: Task<Void, Never>?

    /// Task monitoring accessibility setting changes via NotificationCenter
    private var accessibilityTask: Task<Void, Never>?

    // MARK: - Initialization

    init() {
        refreshAppearance()
        refreshAccessibilitySettings()
    }

    // Note: Call stopMonitoring() explicitly before releasing.
    // deinit cannot access @MainActor-isolated state in Swift 6.

    // MARK: - Monitoring

    /// Starts observing system appearance and accessibility setting changes.
    /// Call this once from a structured task context (e.g., `.task` modifier on the root view).
    func startMonitoring() {
        guard appearanceTask == nil else { return }

        // Observe dark/light mode changes via KVO on NSApp.effectiveAppearance
        appearanceTask = Task { [weak self] in
            let stream = AsyncStream<Void> { continuation in
                let observation = NSApp.observe(\.effectiveAppearance) { _, _ in
                    continuation.yield()
                }
                continuation.onTermination = { _ in
                    _ = observation // prevent the observation from being deallocated
                }
            }
            for await _ in stream {
                guard let self else { return }
                self.refreshAppearance()
            }
        }

        // Observe accessibility setting changes via system notification
        accessibilityTask = Task { [weak self] in
            let notifications = NotificationCenter.default.notifications(
                named: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
            )
            for await _ in notifications {
                guard let self else { return }
                self.refreshAccessibilitySettings()
            }
        }
    }

    /// Stops monitoring for system changes.
    func stopMonitoring() {
        appearanceTask?.cancel()
        appearanceTask = nil
        accessibilityTask?.cancel()
        accessibilityTask = nil
    }

    // MARK: - Refresh

    /// Reads the current system appearance (light/dark mode).
    func refreshAppearance() {
        let appearance = NSApp.effectiveAppearance
        isDarkMode = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// Reads the current accessibility settings from NSWorkspace.
    func refreshAccessibilitySettings() {
        let workspace = NSWorkspace.shared
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
    }

    // MARK: - Materials

    /// Returns the appropriate material for overlay surfaces.
    /// Uses Liquid Glass `.ultraThinMaterial` normally, or an opaque fallback
    /// when Reduce Transparency is enabled.
    var overlayMaterial: Material {
        reduceTransparency ? .bar : .ultraThinMaterial
    }

    /// Returns the appropriate material for popover and panel surfaces.
    /// Uses Liquid Glass `.regularMaterial` normally, or an opaque fallback
    /// when Reduce Transparency is enabled.
    var panelMaterial: Material {
        reduceTransparency ? .bar : .regularMaterial
    }

    // MARK: - Semantic Colors

    /// Primary text color that adapts to light/dark mode and Increase Contrast.
    var primaryTextColor: Color {
        increaseContrast ? (isDarkMode ? .white : .black) : .primary
    }

    /// Secondary text color that adapts to light/dark mode and Increase Contrast.
    var secondaryTextColor: Color {
        increaseContrast ? (isDarkMode ? Color.white.opacity(0.9) : Color.black.opacity(0.9)) : .secondary
    }

    /// Accent color for interactive elements.
    var accentColor: Color {
        .accentColor
    }

    /// Background color for opaque surfaces when Reduce Transparency is on.
    var opaqueBackground: Color {
        isDarkMode ? Color(nsColor: .windowBackgroundColor) : Color(nsColor: .windowBackgroundColor)
    }

    /// Border color that adapts to Increase Contrast.
    var borderColor: Color {
        if increaseContrast {
            return isDarkMode ? .white.opacity(0.6) : .black.opacity(0.6)
        }
        return isDarkMode ? .white.opacity(0.15) : .black.opacity(0.15)
    }

    /// Error color for error states.
    var errorColor: Color {
        .red
    }

    /// Success color for success states.
    var successColor: Color {
        .green
    }

    // MARK: - Animation

    /// The standard spring animation used for overlay show/dismiss and state transitions.
    /// Duration is capped at 300ms per requirement 14.8.
    /// Returns `nil` when Reduce Motion is enabled (requirement 17.5).
    var standardSpringAnimation: Animation? {
        reduceMotion ? nil : .spring(duration: 0.3, bounce: 0.2)
    }

    /// A quick animation for interactive feedback (≤100ms per requirement 14.13).
    /// Returns `nil` when Reduce Motion is enabled.
    var interactiveFeedbackAnimation: Animation? {
        reduceMotion ? nil : .easeOut(duration: 0.1)
    }

    // MARK: - SF Symbols

    /// Returns an SF Symbol name for the given application state.
    ///
    /// Uses centralized `SFSymbols` constants for consistency (Requirement 14.1).
    func menuBarSymbol(for state: AppStateType) -> String {
        switch state {
        case .idle:
            return SFSymbols.menuBarIdle
        case .recording:
            return SFSymbols.menuBarRecording
        case .processing:
            return SFSymbols.menuBarProcessing
        case .error:
            return SFSymbols.menuBarError
        }
    }

    /// Returns an SF Symbol name for common UI actions.
    ///
    /// Uses centralized `SFSymbols` constants for consistency (Requirement 14.1).
    func actionSymbol(_ action: ActionSymbol) -> String {
        switch action {
        case .settings:
            return SFSymbols.settings
        case .quit:
            return SFSymbols.quit
        case .download:
            return SFSymbols.download
        case .delete:
            return SFSymbols.delete
        case .checkmark:
            return SFSymbols.checkmark
        case .warning:
            return SFSymbols.warning
        case .microphone:
            return SFSymbols.microphone
        case .language:
            return SFSymbols.language
        case .model:
            return SFSymbols.model
        case .privacy:
            return SFSymbols.privacy
        case .accessibility:
            return SFSymbols.accessibility
        case .launchAtLogin:
            return SFSymbols.launchAtLogin
        }
    }

    /// Common action symbol identifiers used throughout the app.
    enum ActionSymbol: Sendable {
        case settings
        case quit
        case download
        case delete
        case checkmark
        case warning
        case microphone
        case language
        case model
        case privacy
        case accessibility
        case launchAtLogin
    }
}

// MARK: - SwiftUI View Modifiers

/// Applies the appropriate Liquid Glass material for overlay surfaces,
/// falling back to opaque when Reduce Transparency is enabled.
struct LiquidGlassOverlayModifier: ViewModifier {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    func body(content: Content) -> some View {
        if theme.reduceTransparency {
            content
                .background(theme.opaqueBackground)
        } else {
            content
                .background(theme.overlayMaterial)
        }
    }
}

/// Applies the appropriate Liquid Glass material for panel surfaces,
/// falling back to opaque when Reduce Transparency is enabled.
struct LiquidGlassPanelModifier: ViewModifier {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    func body(content: Content) -> some View {
        if theme.reduceTransparency {
            content
                .background(theme.opaqueBackground)
        } else {
            content
                .background(theme.panelMaterial)
        }
    }
}

/// Applies a spring animation that respects Reduce Motion.
/// When Reduce Motion is on, changes happen instantly without animation.
struct MotionRespectingAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    let value: V

    func body(content: Content) -> some View {
        if let animation = theme.standardSpringAnimation {
            content
                .animation(animation, value: value)
        } else {
            content
        }
    }
}

/// Applies a high-contrast border when Increase Contrast is enabled.
struct HighContrastBorderModifier: ViewModifier {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        if theme.increaseContrast {
            content
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .strokeBorder(theme.borderColor, lineWidth: 1.5)
                )
        } else {
            content
        }
    }
}

/// Applies a visible focus ring around the view when keyboard navigation is active.
/// Requirement 17.8: Display a visible focus indicator on the currently focused interactive element.
struct KeyboardFocusRingModifier: ViewModifier {
    @FocusState private var isFocused: Bool
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isFocused)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(theme.accentColor, lineWidth: isFocused ? 2 : 0)
                    .opacity(isFocused ? 1 : 0)
            )
    }
}

/// Ensures interactive controls meet the 44×44pt minimum touch target size.
/// Requirement 17.12: All interactive controls sized to at least 44×44 points.
struct MinimumTouchTargetModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
    }
}

// MARK: - View Extensions

extension View {
    /// Applies Liquid Glass overlay material with Reduce Transparency fallback.
    func liquidGlassOverlay() -> some View {
        modifier(LiquidGlassOverlayModifier())
    }

    /// Applies Liquid Glass panel material with Reduce Transparency fallback.
    func liquidGlassPanel() -> some View {
        modifier(LiquidGlassPanelModifier())
    }

    /// Applies a spring animation (≤300ms) that respects Reduce Motion.
    func motionRespectingAnimation<V: Equatable>(value: V) -> some View {
        modifier(MotionRespectingAnimationModifier(value: value))
    }

    /// Applies a high-contrast border when Increase Contrast is enabled.
    func highContrastBorder(cornerRadius: CGFloat = 8) -> some View {
        modifier(HighContrastBorderModifier(cornerRadius: cornerRadius))
    }

    /// Applies a visible focus ring when the element is focused via keyboard navigation.
    /// Requirement 17.8: Visible focus indicator on focused interactive elements.
    func keyboardFocusRing() -> some View {
        modifier(KeyboardFocusRingModifier())
    }

    /// Ensures the view meets the 44×44pt minimum touch target size.
    /// Requirement 17.12: Minimum target size for all interactive controls.
    func minimumTouchTarget() -> some View {
        modifier(MinimumTouchTargetModifier())
    }

    /// Applies themed primary text color.
    func themedPrimaryText() -> some View {
        @Environment(UIThemeEngine.self) var theme: UIThemeEngine
        return foregroundStyle(theme.primaryTextColor)
    }

    /// Applies themed secondary text color.
    func themedSecondaryText() -> some View {
        @Environment(UIThemeEngine.self) var theme: UIThemeEngine
        return foregroundStyle(theme.secondaryTextColor)
    }
}


