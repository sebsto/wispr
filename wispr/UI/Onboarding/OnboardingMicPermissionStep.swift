//
//  OnboardingMicPermissionStep.swift
//  wispr
//
//  Microphone permission step for the onboarding flow.
//  Requirements: 13.3, 13.4, 13.5
//

import SwiftUI

/// Microphone permission step with explanation and request button.
struct OnboardingMicPermissionStep: View {
    @Environment(PermissionManager.self) private var permissionManager: PermissionManager
    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: theme.actionSymbol(.microphone))
                .font(.system(size: 48))
                .foregroundStyle(permissionManager.microphoneStatus == .authorized ? theme.successColor : theme.accentColor)
                .accessibilityHidden(true)

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wisp uses your microphone to listen to your voice and transcribe it into text. Audio is processed entirely on your Mac and never sent anywhere.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
                .lineSpacing(4)

            if permissionManager.microphoneStatus == .authorized {
                Label("Microphone Access Granted", systemImage: theme.actionSymbol(.checkmark))
                    .font(.headline)
                    .foregroundStyle(theme.successColor)
                    .accessibilityLabel("Microphone access granted")
            } else {
                Button {
                    Task {
                        await permissionManager.requestMicrophoneAccess()
                    }
                } label: {
                    Label("Grant Microphone Access", systemImage: theme.actionSymbol(.microphone))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityLabel("Grant Microphone Access")
                .accessibilityHint("Opens the system dialog to allow microphone access")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Microphone Permission step")
    }
}
