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
    /// The assertion only runs on an ANSI layout. On Colemak/Dvorak/non-Latin
    /// layouts the resolver returns a different keycode or nil (the fallback
    /// case), so a developer running the suite on such a layout skips rather
    /// than gets a false failure.
    @Test("v resolves to the ANSI V position on a US layout")
    func vResolvesToAnsiPositionOnUSLayout() throws {
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        try #require(source != nil, "No active keyboard layout input source")

        // Only meaningful on a US ANSI layout; skip elsewhere so a non-QWERTY
        // dev machine (where "v" may resolve to a different key, or to nil on a
        // non-Latin layout) doesn't produce a false failure.
        guard isAnsiLayout else { return }

        #expect(
            LayoutKeyResolver.keyCode(for: "v") == 0x09,
            "On a US ANSI layout, 'v' should resolve to kVK_ANSI_V (0x09)"
        )
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
