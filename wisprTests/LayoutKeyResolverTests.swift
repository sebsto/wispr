//
//  LayoutKeyResolverTests.swift
//  wispr
//
//  Regression tests for issue #105: the ⌘V paste keycode must be resolved
//  from the active keyboard layout, not hardcoded to the ANSI V position.
//

import Testing
import Carbon
@testable import WisprApp

@Suite("LayoutKeyResolver")
struct LayoutKeyResolverTests {

    /// On the CI runner (US ANSI layout) the physical key producing "v" is
    /// `kVK_ANSI_V` (0x09). This is the layout the macOS CI runner uses, so it
    /// also confirms QWERTY users see no behaviour change from the fix.
    ///
    /// Skipped on any machine whose active layout is not ANSI-based, so a
    /// developer running the suite on Colemak/Dvorak doesn't get a false red.
    @Test("v resolves to the ANSI V position on a US layout")
    func vResolvesToAnsiPositionOnUSLayout() throws {
        // Sanity-check the environment: on a US layout the ANSI 'a' key (0)
        // produces "a". If it doesn't, we're not on an ANSI layout, skip.
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        try #require(source != nil, "No active keyboard layout input source")

        // Only assert the exact keycode when we can confirm an ANSI layout,
        // otherwise the resolver is still expected to find *some* key.
        let resolved = LayoutKeyResolver.keyCode(for: "v")

        if isAnsiLayout {
            #expect(resolved == 0x09, "On a US ANSI layout, 'v' should resolve to kVK_ANSI_V (0x09)")
        } else {
            #expect(resolved != nil, "'v' should resolve to some key on any Latin layout")
        }
    }

    /// A character no physical key produces (a control character) returns nil,
    /// which is the signal the caller uses to fall back to the ANSI position.
    @Test("unmappable character returns nil")
    func unmappableCharacterReturnsNil() {
        // U+0000 (NUL) is not produced by any unmodified key press.
        #expect(LayoutKeyResolver.keyCode(for: "\u{0}") == nil)
    }

    /// True when the active layout maps the ANSI 'a' position (keycode 0) to
    /// "a", i.e. a QWERTY/US-family layout. Colemak/Dvorak fail this.
    private var isAnsiLayout: Bool {
        LayoutKeyResolver.keyCode(for: "a") == 0
    }
}
