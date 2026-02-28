//
//  HotkeyRecorderView.swift
//  wispr
//
//  A control that displays the current hotkey and captures a new
//  key combination when activated.
//

import SwiftUI
import Carbon

struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @Binding var isRecording: Bool
    @Binding var errorMessage: String?

    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    @State private var isHovering = false

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) {
                isRecording.toggle()
                if !isRecording {
                    errorMessage = nil
                }
            }
        } label: {
            HStack(spacing: 6) {
                if isRecording {
                    Image(systemName: SFSymbols.recordCircle)
                        .foregroundStyle(theme.errorColor)
                        .symbolEffect(.pulse, isActive: true)
                    Text("Press keys\u{2026}")
                        .foregroundStyle(.secondary)
                } else {
                    Text(KeyCodeMapping.hotkeyDisplayString(keyCode: keyCode, modifiers: modifiers))
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
        .buttonStyle(.bordered)
        .clipShape(.rect(cornerRadius: 8))
        .scaleEffect(isHovering && !theme.reduceMotion ? 1.02 : 1.0)
        .animation(theme.reduceMotion ? nil : .smooth(duration: 0.15), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
        }
        .highContrastBorder(cornerRadius: 8)
        .keyboardFocusRing()
        .accessibilityLabel(
            isRecording
                ? "Recording hotkey, press desired key combination"
                : "Current hotkey: \(KeyCodeMapping.hotkeyDisplayString(keyCode: keyCode, modifiers: modifiers))"
        )
        .accessibilityHint("Click to record a new hotkey")
        .onKeyPress(phases: .down) { keyPress in
            guard isRecording else { return .ignored }
            handleKeyPress(keyPress)
            return .handled
        }
    }

    private func handleKeyPress(_ keyPress: KeyPress) {
        // Escape cancels recording without changing the hotkey (§3.4)
        if keyPress.key == .escape {
            isRecording = false
            errorMessage = nil
            return
        }

        var carbonModifiers: UInt32 = 0
        if keyPress.modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }
        if keyPress.modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }
        if keyPress.modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }
        if keyPress.modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }

        guard carbonModifiers != 0 else {
            errorMessage = "Hotkey must include at least one modifier key (\u{2318}, \u{2325}, \u{2303}, or \u{21E7})"
            return
        }

        guard let char = keyPress.characters.lowercased().first,
              let newKeyCode = KeyCodeMapping.keyCode(for: char) else {
            errorMessage = "Unsupported key. Use a standard letter, number, or punctuation key."
            return
        }

        keyCode = newKeyCode
        modifiers = carbonModifiers
        isRecording = false
        errorMessage = nil
    }
}
