//
//  LayoutKeyResolver.swift
//  wispr
//
//  Resolves which physical key produces a given character on the user's
//  currently-active keyboard layout.
//

import Carbon
import Foundation

/// Finds the physical virtual key code that types a given character on the
/// keyboard layout the user has active right now.
///
/// ## Why this exists
///
/// `CGEvent(virtualKey:)` posts a *physical* key position, not a character.
/// macOS then runs that position through the active layout to decide which
/// character it means. Position `kVK_ANSI_V` (`0x09`) produces "v" on QWERTY,
/// but "d" on Colemak DH and a different letter on Dvorak. So synthesizing
/// ⌘V by hardcoding `0x09` posts ⌘D (or worse) on non-QWERTY layouts, which
/// is how the paste-becomes-bookmark bug happens (issue #105).
///
/// This resolver asks the system, at call time, "which physical key yields
/// 'v' on the layout in use?" and returns that keycode so the synthesized
/// ⌘V actually pastes regardless of layout.
///
/// Resolution is done live rather than from a fixed table because the user
/// can switch layouts while the app is running.
enum LayoutKeyResolver {

    /// The physical keys we scan. macOS virtual key codes for typeable keys
    /// live in 0...127; we probe the whole range and let the layout tell us
    /// which position maps to the character we want.
    private static let candidateKeyCodes: ClosedRange<UInt16> = 0...127

    /// Returns the virtual key code that produces `character` on the currently
    /// active keyboard layout, or `nil` if no key on this layout produces it
    /// (e.g. a non-Latin layout with no "v" key). Callers fall back to a
    /// hardcoded ANSI position in that case.
    ///
    /// - Parameter character: The lowercase character to resolve, e.g. "v".
    static func keyCode(for character: Character) -> UInt16? {
        guard let layoutData = currentLayoutData() else { return nil }

        return layoutData.withUnsafeBytes { rawBuffer -> UInt16? in
            guard let base = rawBuffer.baseAddress else { return nil }
            let layoutPtr = base.assumingMemoryBound(to: UCKeyboardLayout.self)

            for keyCode in candidateKeyCodes {
                if translates(keyCode: keyCode, to: character, using: layoutPtr) {
                    return keyCode
                }
            }
            return nil
        }
    }

    // MARK: - Private

    /// The `uchr` layout data for the active input source, or `nil` if the
    /// active source has no Unicode layout data (some IME sources don't).
    private static func currentLayoutData() -> Data? {
        // Prefer the keyboard *layout* input source; fall back to the general
        // current input source (an IME's ASCII-capable layout) if the layout
        // one is unavailable.
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
            ?? TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        guard let source else { return nil }

        guard let dataPtr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return nil
        }
        let cfData = Unmanaged<CFData>.fromOpaque(dataPtr).takeUnretainedValue()
        return cfData as Data
    }

    /// True if pressing `keyCode` (no modifiers) on the given layout produces
    /// exactly `character`.
    private static func translates(
        keyCode: UInt16,
        to character: Character,
        using layoutPtr: UnsafePointer<UCKeyboardLayout>
    ) -> Bool {
        var deadKeyState: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)

        let status = UCKeyTranslate(
            layoutPtr,
            keyCode,
            UInt16(kUCKeyActionDown),
            0,                       // no modifier keys
            UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit),
            &deadKeyState,
            chars.count,
            &length,
            &chars
        )

        guard status == noErr, length > 0 else { return false }
        let produced = String(utf16CodeUnits: chars, count: length)
        return produced == String(character)
    }
}
