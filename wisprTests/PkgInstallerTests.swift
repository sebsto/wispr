//
//  PkgInstallerTests.swift
//  wisprTests
//
//  Property-based tests for the pkg-installer build pipeline.
//  See .kiro/specs/pkg-installer/design.md — "Correctness Properties".
//
//  These exercise the shell commands the Makefile relies on (jq, sed, file
//  existence checks) via Process, rather than the Makefile itself. Each
//  property runs at least 100 randomized iterations.
//

import Testing
import Foundation

@Suite("pkg-installer Properties")
struct PkgInstallerTests {

    // Runs a command, returns (exitCode, trimmedStdout).
    private func run(_ launchPath: String, _ args: [String], stdin: String? = nil) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args

        let outPipe = Pipe()
        process.standardOutput = outPipe
        // Inherit the test process's stderr rather than an unconsumed Pipe():
        // a child that writes enough to a full, undrained stderr pipe would block
        // and hang the test run. This keeps diagnostics visible and avoids deadlock.
        process.standardError = FileHandle.standardError

        if let stdin {
            let inPipe = Pipe()
            process.standardInput = inPipe
            inPipe.fileHandleForWriting.write(Data(stdin.utf8))
            inPipe.fileHandleForWriting.closeFile()
        }

        do {
            try process.run()
        } catch {
            return (-1, "")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (process.terminationStatus, output)
    }

    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pkg-installer-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // `jq` is not part of a stock macOS install. Skip jq-dependent tests on a
    // clean machine rather than failing the whole app test run.
    private var isJQAvailable: Bool {
        run("/usr/bin/env", ["jq", "--version"]).0 == 0
    }

    // MARK: - Property 1: Installer identity extraction round trip
    // Validates: Requirements 3.2, 7.2

    @Test("Property 1: installer_identity extracted via jq round-trips exactly")
    func testInstallerIdentityRoundTrip() throws {
        try #require(isJQAvailable, "jq not installed — skipping jq round-trip property")

        let teamIDs = ["ABCDE12345", "9Z8Y7X6W5V", "TEAMID0001", "QWERTYUIOP"]
        let names = ["Jane Doe", "Acme Corp", "S. Stormacq", "Développeur"]

        for _ in 0..<100 {
            let name = names.randomElement()!
            let team = teamIDs.randomElement()!
            let identity = "Developer ID Installer: \(name) (\(team))"

            let dir = try tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let jsonURL = dir.appendingPathComponent("asc-api-key.json")

            let object: [String: Any] = [
                "apple_api_key_id": "KEY\(Int.random(in: 1000...9999))",
                "apple_api_issuer_id": UUID().uuidString,
                "apple_api_key": "base64data",
                "installer_identity": identity,
            ]
            let data = try JSONSerialization.data(withJSONObject: object)
            try data.write(to: jsonURL)

            let (code, output) = run("/usr/bin/env", ["jq", "-r", ".installer_identity", jsonURL.path])
            #expect(code == 0)
            #expect(output == identity)
        }
    }

    // MARK: - Property 2: Output package filename follows version pattern
    // Validates: Requirements 5.2

    @Test("Property 2: Makefile FINAL_PKG resolves to <EXPORT_DIR>/wispr-<VERSION>.pkg")
    func testOutputFilenamePattern() throws {
        // Derive the output path from the Makefile's ACTUAL variable definitions
        // rather than a string rebuilt in the test, so a change to the packaging
        // output-path logic (renamed var, moved dir, altered filename pattern)
        // makes this fail. macOS ships GNU Make 3.81, which lacks a reliable way to
        // print a resolved variable, so we read + expand the definitions ourselves.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // wisprTests/
            .deletingLastPathComponent()   // repo root
        let makefile = root.appendingPathComponent("Makefile")
        let makefileText = try String(contentsOf: makefile, encoding: .utf8)

        // Grab the right-hand side of a `NAME := value` (or `NAME = value`) assignment.
        func rhs(of name: String) -> String? {
            for line in makefileText.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix(name) else { continue }
                let after = trimmed.dropFirst(name.count).trimmingCharacters(in: .whitespaces)
                guard after.hasPrefix(":=") || after.hasPrefix("=") else { continue }
                return after.drop(while: { $0 == ":" || $0 == "=" })
                    .trimmingCharacters(in: .whitespaces)
            }
            return nil
        }

        let exportDirDef = try #require(rhs(of: "EXPORT_DIR"), "EXPORT_DIR not found in Makefile")
        let finalPkgDef = try #require(rhs(of: "FINAL_PKG"), "FINAL_PKG not found in Makefile")

        // EXPORT_DIR := $(CURDIR)/build/export  → resolve $(CURDIR) to the repo root.
        let exportDir = exportDirDef.replacingOccurrences(of: "$(CURDIR)", with: root.path)
        #expect(exportDir.hasSuffix("/build/export"),
                "EXPORT_DIR resolved to \(exportDir), expected to end with /build/export")

        for _ in 0..<100 {
            let x = Int.random(in: 0...99)
            let y = Int.random(in: 0...99)
            let z = Int.random(in: 0...99)
            let version = "\(x).\(y).\(z)"

            // Resolve FINAL_PKG (:= $(EXPORT_DIR)/wispr-$(VERSION).pkg) for this VERSION.
            let resolved = finalPkgDef
                .replacingOccurrences(of: "$(EXPORT_DIR)", with: exportDir)
                .replacingOccurrences(of: "$(VERSION)", with: version)

            let filename = (resolved as NSString).lastPathComponent
            #expect(filename == "wispr-\(version).pkg",
                    "FINAL_PKG basename was \(filename), expected wispr-\(version).pkg")
            #expect(resolved.hasSuffix("/build/export/wispr-\(version).pkg"),
                    "FINAL_PKG resolved to \(resolved), expected to end with /build/export/wispr-\(version).pkg")
        }
    }

    // MARK: - Property 3: Marketing version injection
    // Validates: Requirements 6.1

    @Test("Property 3: sed rewrites every MARKETING_VERSION to the new value")
    func testMarketingVersionInjection() throws {
        for _ in 0..<100 {
            let old = "\(Int.random(in: 0...9)).\(Int.random(in: 0...9)).\(Int.random(in: 0...9))"
            let new = "\(Int.random(in: 10...99)).\(Int.random(in: 0...99)).\(Int.random(in: 0...99))"

            let dir = try tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let pbxURL = dir.appendingPathComponent("project.pbxproj")

            let content = """
            \t\t\t\tPRODUCT_NAME = wispr;
            \t\t\t\tMARKETING_VERSION = \(old);
            \t\t\t\tOTHER_SETTING = 1;
            \t\t\t\tMARKETING_VERSION = \(old);
            """
            try content.write(to: pbxURL, atomically: true, encoding: .utf8)

            let (code, _) = run("/usr/bin/sed", [
                "-i", "",
                "s/MARKETING_VERSION = [^;]*/MARKETING_VERSION = \(new)/g",
                pbxURL.path,
            ])
            #expect(code == 0)

            let result = try String(contentsOf: pbxURL, encoding: .utf8)
            let entries = result.components(separatedBy: "\n")
                .filter { $0.contains("MARKETING_VERSION") }
            #expect(!entries.isEmpty)
            for entry in entries {
                #expect(entry.contains("MARKETING_VERSION = \(new);"))
                #expect(!entry.contains("= \(old);"))
            }
        }
    }

    // MARK: - Property 4: Missing resource file detection
    // Validates: Requirements 8.4

    @Test("Property 4: validation names the missing installer resource")
    func testMissingResourceFileDetection() throws {
        let required = ["background.png", "background-darkAqua.png", "welcome.html", "readme.html", "license.txt"]

        for _ in 0..<100 {
            let missing = required.randomElement()!

            let dir = try tempDir()
            defer { try? FileManager.default.removeItem(at: dir) }
            let resources = dir.appendingPathComponent("resources")
            try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

            for file in required where file != missing {
                try Data("x".utf8).write(to: resources.appendingPathComponent(file))
            }

            // Mirror the Makefile validation loop, which echoes the FULL path
            // of the missing resource (`$$f`), not just the basename.
            let script = required.map { file in
                let path = "\(resources.path)/\(file)"
                return "test -f \"\(path)\" || { echo \"Error: missing installer resource: \(path)\"; exit 1; }"
            }.joined(separator: "; ")

            let missingPath = "\(resources.path)/\(missing)"
            let (code, output) = run("/bin/sh", ["-c", script])
            #expect(code != 0)
            #expect(output.contains("Error: missing installer resource: \(missingPath)"))
            #expect(output.contains(missing))
        }
    }
}
