//
//  OnboardingCompletionStep.swift
//  wispr
//
//  Completion step for the onboarding flow.
//

import SwiftUI

/// Final step confirming that Wisp is configured and ready to use.
struct OnboardingCompletionStep: View {
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: SFSymbols.onboardingComplete)
                .font(.system(size: 56))
                .foregroundStyle(theme.successColor)
                .accessibilityHidden(true)

            Text("You're All Set!")
                .font(.title)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp is configured and ready to use. Press ⌥Space to start dictating at any time.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .lineSpacing(4)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup complete. Wisp is ready. Press Option Space to start dictating.")
    }
}
