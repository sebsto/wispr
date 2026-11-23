//
//  ModelAliasTests.swift
//  wispr
//

import Foundation
import Testing
@testable import WisprCLI
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

@Suite("CLI model resolution")
struct CLIModelResolutionTests {
    private static let turbo = ModelInfo.KnownID.largeV3Turbo

    private static func models(_ names: String...) -> [DownloadedModelInfo] {
        names.map {
            DownloadedModelInfo(name: $0, sizeOnDisk: 1_500_000_000, path: URL(fileURLWithPath: "/tmp/\($0)"))
        }
    }

    @Test("An alias resolves to the downloaded turbo model")
    func aliasResolves() throws {
        let downloaded = Self.models("large-v3", Self.turbo)
        #expect(try WisprCLI.resolve("turbo", among: downloaded, activeModel: nil) == Self.turbo)
    }

    @Test("The full ID still resolves")
    func fullIDResolves() throws {
        let downloaded = Self.models(Self.turbo)
        #expect(try WisprCLI.resolve(Self.turbo, among: downloaded, activeModel: nil) == Self.turbo)
    }

    @Test("An alias for a model that is not downloaded is reported as not found")
    func aliasNotDownloaded() {
        let downloaded = Self.models("large-v3")
        #expect(throws: CLIError.self) {
            try WisprCLI.resolve("turbo", among: downloaded, activeModel: nil)
        }
    }

    @Test("The not-found message lists downloaded models with their aliases")
    func notFoundMessage() {
        let downloaded = Self.models("large-v3", Self.turbo)
        do {
            _ = try WisprCLI.resolve("nope", among: downloaded, activeModel: nil)
            Issue.record("Expected modelNotFound")
        } catch {
            let message = String(describing: error)
            #expect(message.contains("'nope'"))
            #expect(message.contains("large-v3"))
            #expect(message.contains("\(Self.turbo) (alias: large-v3-turbo, turbo, turbo-v3)"))
        }
    }

    @Test("Without a name, the active model is used when downloaded")
    func activeModel() throws {
        let downloaded = Self.models("large-v3", Self.turbo)
        #expect(try WisprCLI.resolve(nil, among: downloaded, activeModel: "large-v3") == "large-v3")
        #expect(throws: CLIError.self) {
            try WisprCLI.resolve(nil, among: downloaded, activeModel: "tiny")
        }
    }

    @Test("displayName appends aliases only for models that have them")
    func displayName() {
        #expect(WisprCLI.displayName(for: "large-v3") == "large-v3")
        #expect(WisprCLI.displayName(for: Self.turbo) == "\(Self.turbo) (alias: large-v3-turbo, turbo, turbo-v3)")
    }

    @Test("--list-models keeps the bare ID in the first column")
    func listLineFirstColumn() {
        let model = Self.models(Self.turbo)[0]
        let line = WisprCLI.listLine(for: model, isActive: true)
        let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
        #expect(columns.count == 3)
        #expect(columns[0] == Self.turbo)
        #expect(columns[1] == "1500 MB (active)")
        #expect(columns[2] == "aliases: large-v3-turbo, turbo, turbo-v3")
    }

    @Test("--list-models adds no alias column for models without aliases")
    func listLineNoAliases() {
        let line = WisprCLI.listLine(for: Self.models("large-v3")[0], isActive: false)
        #expect(line == "large-v3\t1500 MB")
    }
}
