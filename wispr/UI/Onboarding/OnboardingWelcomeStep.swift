//
//  OnboardingWelcomeStep.swift
//  wispr
//
//  Welcome step content for the onboarding flow.
//

import SwiftUI

/// Welcome step that introduces the user to Wisp.
struct OnboardingWelcomeStep: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: SFSymbols.onboardingWelcome)
                .font(.system(size: 56))
                .foregroundStyle(theme.accentColor)
                .accessibilityHidden(true)

            Text("Welcome to Wisp")
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp lets you dictate text anywhere on your Mac using a global hotkey. All transcription happens on-device — your voice never leaves your computer.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .lineSpacing(4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Welcome to Wisp. Dictate text anywhere on your Mac. All transcription happens on-device.")
    }
}
