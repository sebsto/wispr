//
//  TranscriptExportDestinationTests.swift
//  wisprTests
//
//  Covers which export destinations are offered, based on installed apps.
//

import Foundation
import Testing

@testable import WisprApp

/// Reports a fixed set of bundle identifiers as installed.
struct FakeAppInstallDetector: AppInstallDetecting {
    var installed: Set<String>

    func isInstalled(bundleIdentifier: String) -> Bool {
        installed.contains(bundleIdentifier)
    }
}

@Suite("Transcript export destination Tests")
struct TranscriptExportDestinationTests {

    @Test("Obsidian is detected when its app is installed")
    func testObsidianInstalled() {
        let detector = FakeAppInstallDetector(installed: ["md.obsidian"])
        #expect(TranscriptExportDestination.detected(using: detector) == [.obsidian])
    }

    @Test("No destination is offered when none of the apps is installed")
    func testNothingInstalled() {
        let detector = FakeAppInstallDetector(installed: ["com.apple.Notes"])
        #expect(TranscriptExportDestination.detected(using: detector).isEmpty)
    }

    @Test("Destination ids are unique")
    func testIdsAreUnique() {
        let ids = TranscriptExportDestination.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}
