//
//  KeyCodeMapping.swift
//  wispr
//
//  Unified bidirectional mapping between macOS virtual key codes,
//  display strings, and typeable characters.
//  Uses Carbon virtual key codes (Inside Macintosh, Vol. V).
//

import Carbon

enum KeyCodeMapping {

    /// Single source of truth: virtual key code → display name.
    /// Includes typeable keys, function keys, navigation keys, and special keys.
    static let keyNames: [UInt32: String] = [
        // Letters (ANSI layout order)
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 31: "O", 32: "U", 34: "I", 35: "P", 37: "L",
        38: "J", 40: "K", 45: "N", 46: "M",
        // Digits
        18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 25: "9", 26: "7", 28: "8", 29: "0",
        // Punctuation
        24: "=", 27: "-", 30: "]", 33: "[", 39: "'",
        41: ";", 42: "\\", 43: ",", 44: "/", 47: ".",
        // Whitespace & editing
        49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
        53: "Escape", 76: "Enter", 117: "Forward Delete",
        // Function keys
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5",
        97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
        103: "F11", 111: "F12", 105: "F13", 113: "F14",
        // Navigation
        115: "Home", 119: "End", 116: "PageUp", 121: "PageDown",
        123: "\u{2190}", 124: "\u{2192}", 125: "\u{2193}", 126: "\u{2191}",
    ]

    /// Derived reverse mapping: lowercase character → virtual key code.
    /// Only maps single-character key names (letters, digits, punctuation).
    private static let charToKeyCode: [Character: UInt32] = {
        var map: [Character: UInt32] = [:]
        for (code, name) in keyNames where name.count == 1 {
            map[Character(name.lowercased())] = code
        }
        map[" "] = 49 // Space
        return map
    }()

    /// Returns the virtual key code for a typeable character, or `nil` for unmapped characters.
    static func keyCode(for character: Character) -> UInt32? {
        charToKeyCode[character]
    }

    /// Returns a human-readable display string for a virtual key code.
    static func displayString(for keyCode: UInt32) -> String {
        keyNames[keyCode] ?? "Key \(keyCode)"
    }

    /// Builds a display string for modifier flags using standard macOS symbols.
    static func modifierDisplayString(for carbonModifiers: UInt32) -> String {
        var parts: [String] = []
        if carbonModifiers & UInt32(controlKey) != 0 { parts.append("\u{2303}") }
        if carbonModifiers & UInt32(optionKey) != 0 { parts.append("\u{2325}") }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts.append("\u{21E7}") }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts.append("\u{2318}") }
        return parts.joined()
    }

    /// Full hotkey display string: modifier symbols + key name.
    static func hotkeyDisplayString(keyCode: UInt32, modifiers: UInt32) -> String {
        modifierDisplayString(for: modifiers) + displayString(for: keyCode)
    }
}
