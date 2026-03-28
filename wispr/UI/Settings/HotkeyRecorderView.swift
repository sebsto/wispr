//
//  HotkeyRecorderView.swift
//  wispr
//
//  A control that displays the current hotkey and captures a new
//  key combination when activated.
//

import AppKit
import SwiftUI
import Carbon

struct HotkeyRecorderView: View {
    @Binding var keyCode: UInt32
    @Binding var modifiers: UInt32
    @Binding var isRecording: Bool
    @Binding var errorMessage: String?

    @Environment(UIThemeEngine.self) private var theme: UIThemeEngine

    @State private var isHovering = false
    @State private var fnMonitor: Any?

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
                    Text(KeyCodeMapping.shared.hotkeyDisplayString(keyCode: keyCode, modifiers: modifiers))
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
                : "Current hotkey: \(KeyCodeMapping.shared.hotkeyDisplayString(keyCode: keyCode, modifiers: modifiers))"
        )
        .accessibilityHint("Click to record a new hotkey")
        .onKeyPress(phases: .down) { keyPress in
            guard isRecording else { return .ignored }
            handleKeyPress(keyPress)
            return .handled
        }
        .onChange(of: isRecording) { _, recording in
            if recording {
                installFnMonitor()
            } else {
                removeFnMonitor()
            }
        }
        .onDisappear {
            removeFnMonitor()
        }
    }

    private func installFnMonitor() {
        fnMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
            guard isRecording else { return event }

            // Pass through if other modifiers are held (Fn+Cmd, Fn+Opt, etc.)
            // This matches HotkeyMonitor.handleFnFlagsChanged() which also
            // rejects combined modifier presses.
            let otherModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
            if !event.modifierFlags.intersection(otherModifiers).isEmpty {
                return event
            }

            // Detect Fn via the .function modifier flag rather than keyCode,
            // because Apple Silicon Macs may report a keycode other than 63.
            // Only accept the press (function flag set), not the release.
            if event.modifierFlags.contains(.function) {
                keyCode = UInt32(HotkeyMonitor.fnKeyCode)
                modifiers = 0
                isRecording = false
                errorMessage = nil
                return nil  // consume
            }
            return event
        }
    }

    private func removeFnMonitor() {
        if let monitor = fnMonitor {
            NSEvent.removeMonitor(monitor)
            fnMonitor = nil
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

        // Use keyPress.key.character (unmodified logical key) instead of
        // keyPress.characters (which is altered by modifiers, e.g. Option+Space
        // produces non-breaking space, Option+A produces "å").
        let logicalChar = Character(String(keyPress.key.character).lowercased())
        guard let newKeyCode = KeyCodeMapping.shared.keyCode(for: logicalChar) else {
            errorMessage = "Unsupported key. Use a standard letter, number, or punctuation key."
            return
        }

        keyCode = newKeyCode
        modifiers = carbonModifiers
        isRecording = false
        errorMessage = nil
    }
}
