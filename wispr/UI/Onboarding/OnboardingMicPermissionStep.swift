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
            OnboardingIconBadge(
                systemName: theme.actionSymbol(.microphone),
                color: permissionManager.microphoneStatus == .authorized
                    ? theme.successColor : theme.accentColor
            )

            Text("Microphone Access")
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(theme.primaryTextColor)

            Text("Wispr uses your microphone to listen to your voice and transcribe it into text. Audio is processed entirely on your Mac and never sent anywhere.")
                .font(.body)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .lineSpacing(5)

            switch permissionManager.microphoneStatus {
            case .authorized:
                Label("Microphone Access Granted", systemImage: theme.actionSymbol(.checkmark))
                    .font(.headline)
                    .foregroundStyle(theme.successColor)
                    .transition(.scale.combined(with: .opacity))
                    .accessibilityLabel("Microphone access granted")

            case .denied:
                VStack(spacing: 12) {
                    Label("Microphone Access Denied", systemImage: "xmark.circle")
                        .font(.headline)
                        .foregroundStyle(.red)

                    Text("Wispr cannot work without microphone access. Please enable it in System Settings, then return here.")
                        .font(.callout)
                        .foregroundStyle(theme.secondaryTextColor)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)

                    Button {
                        NSWorkspace.shared.open(
                            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
                        )
                    } label: {
                        Label("Open System Settings", systemImage: "gear")
                    }
                    .buttonStyle(OnboardingContinueButtonStyle())
                    .accessibilityHint("Opens Privacy & Security settings to enable microphone access")
                }

            case .notDetermined:
                Button {
                    Task {
                        await permissionManager.requestMicrophoneAccess()
                    }
                } label: {
                    Label("Grant Microphone Access", systemImage: theme.actionSymbol(.microphone))
                }
                .buttonStyle(OnboardingContinueButtonStyle())
                .accessibilityLabel("Grant Microphone Access")
                .accessibilityHint("Opens the system dialog to allow microphone access")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Microphone Permission step")
    }
}
