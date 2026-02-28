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

    @State private var appeared = false

    var body: some View {
        VStack(spacing: 20) {
            OnboardingIconBadge(
                systemName: SFSymbols.onboardingComplete,
                color: theme.successColor,
                isLarge: true
            )
            .scaleEffect(appeared ? 1.0 : 0.5)
            .opacity(appeared ? 1.0 : 0)

            Text("You're All Set!")
                .font(.title)
                .fontWeight(.bold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp is configured and ready to use. Press ⌥Space to start dictating at any time.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .lineSpacing(5)
        }
        .onAppear {
            guard !theme.reduceMotion else {
                appeared = true
                return
            }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                appeared = true
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Setup complete. Wisp is ready. Press Option Space to start dictating.")
    }
}
