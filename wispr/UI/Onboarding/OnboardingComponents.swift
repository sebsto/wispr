//
//  OnboardingComponents.swift
//  wispr
//
//  Reusable UI components for the onboarding flow.
//

import SwiftUI

// MARK: - Icon Badge

/// A large SF Symbol displayed inside a gradient-filled circle with a soft shadow.
///
/// Creates a visually prominent focal point for each onboarding step.
struct OnboardingIconBadge: View {
    let systemName: String
    let color: Color
    var isLarge = false

    @ScaledMetric(relativeTo: .title) private var regularBadgeSize = 88.0
    @ScaledMetric(relativeTo: .largeTitle) private var largeBadgeSize = 104.0
    @ScaledMetric(relativeTo: .title) private var regularIconSize = 36.0
    @ScaledMetric(relativeTo: .largeTitle) private var largeIconSize = 44.0

    private var badgeSize: CGFloat { isLarge ? largeBadgeSize : regularBadgeSize }
    private var iconSize: CGFloat { isLarge ? largeIconSize : regularIconSize }

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: badgeSize, height: badgeSize)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [color, color.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: color.opacity(0.25), radius: 16, y: 6)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Button Styles

/// Primary capsule button for Continue, Done, and step action buttons.
///
/// Accent-colored capsule with white text, subtle scale-on-press feedback,
/// and proper disabled state dimming.
struct OnboardingContinueButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 12)
            .frame(minHeight: 44)
            .background(
                Capsule()
                    .fill(Color.accentColor)
                    .opacity(isEnabled ? 1.0 : 0.35)
            )
            .scaleEffect(configuration.isPressed && isEnabled ? 0.96 : 1.0)
            .opacity(isEnabled ? 1.0 : 0.6)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

/// Ghost button for Back and Skip actions.
///
/// Transparent background with subtle press highlight and scale feedback.
struct OnboardingSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(minHeight: 44)
            .background(
                Capsule()
                    .fill(Color.secondary.opacity(configuration.isPressed ? 0.08 : 0))
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
