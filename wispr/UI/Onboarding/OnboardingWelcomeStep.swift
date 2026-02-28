//
//  OnboardingWelcomeStep.swift
//  wispr
//
//  Welcome step content for the onboarding flow.
//

import SwiftUI

/// Welcome step that introduces the user to Wispr.
struct OnboardingWelcomeStep: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    var body: some View {
        VStack(spacing: 20) {
            OnboardingIconBadge(
                systemName: SFSymbols.onboardingWelcome,
                color: theme.accentColor,
                isLarge: true
            )

            Text("Welcome to Wispr")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wispr lets you dictate text anywhere on your Mac using a global hotkey. All transcription happens on-device — your voice never leaves your computer.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .lineSpacing(5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome to Wispr. Dictate text anywhere on your Mac. All transcription happens on-device.")
    }
}
