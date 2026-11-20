//
//  ParakeetLanguageTests.swift
//  wisprTests
//

import Testing
@testable import WisprCore

@Suite("Parakeet language handling")
struct ParakeetLanguageTests {
    @Test("Latin-script languages cannot be enforced", arguments: ["fr", "en", "de", "es"])
    func latinNotEnforced(code: String) {
        #expect(!ParakeetService.canEnforceLanguage(code))
    }

    @Test("Non-Latin-script languages can be enforced", arguments: ["ru", "uk", "el"])
    func nonLatinEnforced(code: String) {
        #expect(ParakeetService.canEnforceLanguage(code))
    }

    @Test("Unknown code is not enforceable")
    func unknownCode() {
        #expect(!ParakeetService.canEnforceLanguage("xx"))
    }

    @Test("Language mapping")
    func mapping() {
        #expect(ParakeetService.fluidAudioLanguage(for: .autoDetect) == nil)
        #expect(ParakeetService.fluidAudioLanguage(for: .specific(code: "xx")) == nil)
        #expect(ParakeetService.fluidAudioLanguage(for: .specific(code: "fr")) != nil)
        #expect(ParakeetService.fluidAudioLanguage(for: .pinned(code: "ru")) != nil)
    }
}
