//
//  OnboardingAccessibilityStep.swift
//  wispr
//
//  Accessibility permission step for the onboarding flow.
//  Requirements: 13.3, 13.4, 13.5
//

import SwiftUI

/// Accessibility permission step with explanation and system settings link.
struct OnboardingAccessibilityStep: View {
    @Environment(PermissionManager.self) private var permissionManager: PermissionManager
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: theme.actionSymbol(.accessibility))
                .font(.system(size: 48))
                .foregroundStyle(permissionManager.accessibilityStatus == .authorized ? theme.successColor : theme.accentColor)
                .accessibilityHidden(true)

            Text("Accessibility Access")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp needs accessibility access to insert transcribed text directly at your cursor position in any application. This permission must be granted in System Settings.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .lineSpacing(4)

            if permissionManager.accessibilityStatus == .authorized {
                Label("Accessibility Access Granted", systemImage: theme.actionSymbol(.checkmark))
                    .font(.headline)
                    .foregroundStyle(theme.successColor)
                    .accessibilityLabel("Accessibility access granted")
            } else {
                Button {
                    permissionManager.openAccessibilitySettings()
                } label: {
                    Label("Open System Settings", systemImage: SFSymbols.settings)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Open System Settings")
                .accessibilityHint("Opens System Settings to the Accessibility privacy pane")

                Text("After enabling Wisp in System Settings, return here to continue.")
                    .font(.callout)
                    .foregroundStyle(theme.secondaryTextColor)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Accessibility Permission step")
    }
}
