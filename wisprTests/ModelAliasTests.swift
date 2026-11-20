//
//  ModelAliasTests.swift
//  wispr
//

import Testing
@testable import WisprCore

@Suite("Model aliases")
struct ModelAliasTests {
    @Test("Short names resolve to the Large v3 Turbo ID",
          arguments: ["turbo", "large-v3-turbo", "turbo-v3", "Turbo"])
    func aliasResolves(name: String) {
        #expect(ModelInfo.canonicalID(for: name) == ModelInfo.KnownID.largeV3Turbo)
    }

    @Test("Full IDs and unknown names are returned unchanged")
    func nonAliasUnchanged() {
        #expect(ModelInfo.canonicalID(for: ModelInfo.KnownID.largeV3Turbo) == ModelInfo.KnownID.largeV3Turbo)
        #expect(ModelInfo.canonicalID(for: "large-v3") == "large-v3")
        #expect(ModelInfo.canonicalID(for: "nope") == "nope")
    }

    @Test("Aliases for an ID are listed sorted")
    func aliasesForID() {
        #expect(ModelInfo.aliases(for: ModelInfo.KnownID.largeV3Turbo) == ["large-v3-turbo", "turbo", "turbo-v3"])
        #expect(ModelInfo.aliases(for: "tiny").isEmpty)
    }
}
