//
//  UpdateChecker.swift
//  wispr
//
//  Checks GitHub Releases for a newer app version at startup.
//

import WisprCore
import Foundation
import os

// MARK: - HTTP Abstraction

protocol HTTPDataProvider: Sendable {
    func data(from url: URL) async throws -> (Data, URLResponse)
}

extension URLSession: HTTPDataProvider {}

// MARK: - UpdateChecker

@MainActor
@Observable
final class UpdateChecker {

    var availableUpdate: AppUpdateInfo?

    private let currentVersion: String?
    private let httpProvider: any HTTPDataProvider

    init(
        currentVersion: String? = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
        httpProvider: any HTTPDataProvider = URLSession.shared
    ) {
        self.currentVersion = currentVersion
        self.httpProvider = httpProvider
    }

    func checkForUpdate() async {
        Log.updateChecker.info("checkForUpdate() started")

        guard let currentVersion else {
            Log.updateChecker.error("currentVersion is nil — CFBundleShortVersionString missing from bundle")
            return
        }
        Log.updateChecker.info("Current app version string: \(currentVersion)")

        guard let current = SemanticVersion(string: currentVersion) else {
            Log.updateChecker.error("Failed to parse current version '\(currentVersion)' as SemanticVersion")
            return
        }
        Log.updateChecker.debug("Parsed current version: \(current.major).\(current.minor).\(current.patch)")

        do {
            let url = URL(string: "https://api.github.com/repos/sebsto/wispr/releases/latest")!
            Log.updateChecker.info("Fetching latest release from \(url.absoluteString)")

            let (data, response) = try await httpProvider.data(from: url)

            if let httpResponse = response as? HTTPURLResponse {
                Log.updateChecker.info("GitHub API response status: \(httpResponse.statusCode)")
                if httpResponse.statusCode != 200 {
                    Log.updateChecker.error("Unexpected HTTP status \(httpResponse.statusCode) — aborting update check")
                    return
                }
            }

            Log.updateChecker.debug("Received \(data.count) bytes from GitHub API")

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            Log.updateChecker.info("Latest release tag: \(release.tagName), assets count: \(release.assets.count)")

            guard let remote = SemanticVersion(string: release.tagName) else {
                Log.updateChecker.error("Failed to parse remote tag '\(release.tagName)' as SemanticVersion")
                return
            }
            Log.updateChecker.debug("Parsed remote version: \(remote.major).\(remote.minor).\(remote.patch)")

            guard remote > current else {
                Log.updateChecker.info("Already up to date — current \(current.major).\(current.minor).\(current.patch) >= remote \(remote.major).\(remote.minor).\(remote.patch)")
                return
            }
            Log.updateChecker.info("Newer version available: \(release.tagName) > \(currentVersion)")

            let zipAsset = release.assets.first { $0.name.hasSuffix(".zip") }
            if let zipAsset {
                Log.updateChecker.debug("Found .zip asset: \(zipAsset.name) — URL: \(zipAsset.browserDownloadURL)")
            } else {
                Log.updateChecker.error("No .zip asset found among \(release.assets.count) assets: \(release.assets.map(\.name))")
                return
            }

            let downloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadURL) }
            guard let downloadURL else {
                Log.updateChecker.error("Failed to construct download URL from: \(zipAsset?.browserDownloadURL ?? "nil")")
                return
            }

            guard let releasePageURL = URL(string: release.htmlURL) else {
                Log.updateChecker.error("Invalid release page URL: \(release.htmlURL)")
                return
            }

            availableUpdate = AppUpdateInfo(
                version: release.tagName,
                releaseNotes: release.body ?? "",
                downloadURL: downloadURL,
                releasePageURL: releasePageURL
            )
            Log.updateChecker.info("Update available — version: \(release.tagName), download: \(downloadURL.absoluteString), releasePage: \(releasePageURL.absoluteString)")
        } catch let decodingError as DecodingError {
            Log.updateChecker.error("JSON decoding failed: \(String(describing: decodingError))")
        } catch {
            Log.updateChecker.error("Update check failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - GitHub API Models

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case assets
    }
}

private struct GitHubAsset: Decodable {
    let name: String
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
    }
}
