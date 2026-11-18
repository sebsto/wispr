//
//  CLIInstallDialogTests.swift
//  wisprTests
//
//  Regression tests ensuring CLI install command path stays aligned with
//  executable names defined in both SPM and Xcode project settings.
//

import Foundation
import Testing
@testable import WisprApp

@Suite("CLI Install Dialog")
struct CLIInstallDialogTests {

    @Test("CLI executable name stays in sync with SPM and Xcode project")
    func testCLIExecutableNameIsInSyncAcrossConfigs() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // wisprTests/
            .deletingLastPathComponent() // repo root

        let packageContents = try String(
            contentsOf: repoRoot.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let xcodeProjectContents = try String(
            contentsOf: repoRoot.appendingPathComponent("wispr.xcodeproj/project.xcproj"),
            encoding: .utf8
        )

        let packageExecutableName = try extractPackageCLIExecutableName(from: packageContents)
        let xcodeExecutableName = try extractXcodeCLIExecutableName(from: xcodeProjectContents)

        #expect(packageExecutableName == xcodeExecutableName)
        #expect(CLIInstallDialogView.cliExecutableName == packageExecutableName)
    }

    private func extractPackageCLIExecutableName(from contents: String) throws -> String {
        // Capture executable target name for the target that maps to Sources/WisprCLI.
        let regex = #/(?s)\.executableTarget\((?:(?!\.executableTarget\().)*?name:\s*"([^"]+)"(?:(?!\.executableTarget\().)*?path:\s*"Sources\/WisprCLI"/#
        guard let match = contents.firstMatch(of: regex) else {
            throw ParseError.patternNotFound("Package.swift executableTarget for Sources/WisprCLI")
        }
        return String(match.1)
    }

    private func extractXcodeCLIExecutableName(from contents: String) throws -> String {
        // Capture the CLI executable file reference specifically (not the app executable).
        let regex = #/\{\s*"path":\s*"<PRODUCTS>\/([^"]+)",[^\n]*"type":\s*"compiled\.mach-o\.executable"/#
        guard let match = contents.firstMatch(of: regex) else {
            throw ParseError.patternNotFound("WisprCLI executable product entry")
        }
        return String(match.1)
    }

    private enum ParseError: Error {
        case patternNotFound(String)
    }
}
