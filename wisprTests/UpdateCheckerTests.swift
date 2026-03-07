//
//  UpdateCheckerTests.swift
//  wispr
//
//  Tests for SemanticVersion parsing/comparison and UpdateChecker logic.
//

import Testing
import Foundation
@testable import wispr

// MARK: - Test Fakes

private struct FakeHTTPProvider: HTTPDataProvider {
    let data: Data

    func data(from url: URL) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (data, response)
    }
}

private struct FailingHTTPProvider: HTTPDataProvider {
    func data(from url: URL) async throws -> (Data, URLResponse) {
        throw URLError(.notConnectedToInternet)
    }
}

// MARK: - GitHub JSON Helpers

private func makeGitHubReleaseJSON(
    tagName: String,
    body: String = "Release notes",
    assetName: String = "wispr.zip",
    assetURL: String = "https://github.com/sebsto/wispr/releases/download/v1.0.7/wispr.zip",
    htmlURL: String = "https://github.com/sebsto/wispr/releases/tag/v1.0.7"
) -> Data {
    """
    {
        "tag_name": "\(tagName)",
        "html_url": "\(htmlURL)",
        "body": "\(body)",
        "assets": [
            {
                "name": "\(assetName)",
                "browser_download_url": "\(assetURL)"
            }
        ]
    }
    """.data(using: .utf8)!
}

// MARK: - SemanticVersion Tests

@Suite("SemanticVersion")
struct SemanticVersionTests {

    @Test("Parses three-part version string")
    func testThreePart() {
        let v = SemanticVersion(string: "1.2.3")
        #expect(v != nil)
        #expect(v?.major == 1)
        #expect(v?.minor == 2)
        #expect(v?.patch == 3)
    }

    @Test("Parses two-part version string with implicit patch zero")
    func testTwoPart() {
        let v = SemanticVersion(string: "2.5")
        #expect(v != nil)
        #expect(v?.major == 2)
        #expect(v?.minor == 5)
        #expect(v?.patch == 0)
    }

    @Test("Strips lowercase v prefix")
    func testLowercaseVPrefix() {
        let v = SemanticVersion(string: "v1.0.6")
        #expect(v != nil)
        #expect(v?.major == 1)
        #expect(v?.minor == 0)
        #expect(v?.patch == 6)
    }

    @Test("Strips uppercase V prefix")
    func testUppercaseVPrefix() {
        let v = SemanticVersion(string: "V3.2.1")
        #expect(v != nil)
        #expect(v?.major == 3)
    }

    @Test("Returns nil for invalid input")
    func testInvalid() {
        #expect(SemanticVersion(string: "abc") == nil)
        #expect(SemanticVersion(string: "") == nil)
        #expect(SemanticVersion(string: "v") == nil)
        #expect(SemanticVersion(string: "1") == nil)
    }

    @Test("Compares versions correctly")
    func testComparison() {
        let v1 = SemanticVersion(string: "1.0.0")!
        let v2 = SemanticVersion(string: "1.0.1")!
        let v3 = SemanticVersion(string: "1.1.0")!
        let v4 = SemanticVersion(string: "2.0.0")!

        #expect(v1 < v2)
        #expect(v2 < v3)
        #expect(v3 < v4)
        #expect(v1 == SemanticVersion(string: "1.0.0")!)
        #expect(!(v2 < v1))
    }
}

// MARK: - UpdateChecker Tests

@MainActor
@Suite("UpdateChecker")
struct UpdateCheckerTests {

    @Test("Sets availableUpdate when remote version is newer")
    func testNewerVersionAvailable() async {
        let json = makeGitHubReleaseJSON(tagName: "v1.0.7")
        let checker = UpdateChecker(
            currentVersion: "1.0.6",
            httpProvider: FakeHTTPProvider(data: json)
        )
        await checker.checkForUpdate()
        #expect(checker.availableUpdate != nil)
        #expect(checker.availableUpdate?.version == "v1.0.7")
    }

    @Test("availableUpdate is nil when versions are equal")
    func testSameVersion() async {
        let json = makeGitHubReleaseJSON(tagName: "v1.0.6")
        let checker = UpdateChecker(
            currentVersion: "1.0.6",
            httpProvider: FakeHTTPProvider(data: json)
        )
        await checker.checkForUpdate()
        #expect(checker.availableUpdate == nil)
    }

    @Test("availableUpdate is nil when remote version is older")
    func testOlderVersion() async {
        let json = makeGitHubReleaseJSON(tagName: "v1.0.5")
        let checker = UpdateChecker(
            currentVersion: "1.0.6",
            httpProvider: FakeHTTPProvider(data: json)
        )
        await checker.checkForUpdate()
        #expect(checker.availableUpdate == nil)
    }

    @Test("availableUpdate is nil on network failure")
    func testNetworkFailure() async {
        let checker = UpdateChecker(
            currentVersion: "1.0.6",
            httpProvider: FailingHTTPProvider()
        )
        await checker.checkForUpdate()
        #expect(checker.availableUpdate == nil)
    }

    @Test("Handles tag_name without v prefix")
    func testTagWithoutPrefix() async {
        let json = makeGitHubReleaseJSON(tagName: "1.0.7")
        let checker = UpdateChecker(
            currentVersion: "1.0.6",
            httpProvider: FakeHTTPProvider(data: json)
        )
        await checker.checkForUpdate()
        #expect(checker.availableUpdate != nil)
    }

    @Test("Handles current version with v prefix")
    func testCurrentVersionWithPrefix() async {
        let json = makeGitHubReleaseJSON(tagName: "v2.0.0")
        let checker = UpdateChecker(
            currentVersion: "v1.0.0",
            httpProvider: FakeHTTPProvider(data: json)
        )
        await checker.checkForUpdate()
        #expect(checker.availableUpdate != nil)
    }
}
