//
//  UpdateChecker.swift
//  wispr
//
//  Checks GitHub Releases for a newer app version at startup.
//

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
        guard let currentVersion,
              let current = SemanticVersion(string: currentVersion) else {
            Log.app.debug("UpdateChecker — unable to determine current version")
            return
        }

        do {
            let url = URL(string: "https://api.github.com/repos/sebsto/wispr/releases/latest")!
            let (data, _) = try await httpProvider.data(from: url)
            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)

            guard let remote = SemanticVersion(string: release.tagName),
                  remote > current else {
                Log.app.debug("UpdateChecker — up to date (\(currentVersion))")
                return
            }

            let zipAsset = release.assets.first { $0.name.hasSuffix(".zip") }
            let downloadURL = zipAsset.flatMap { URL(string: $0.browserDownloadURL) }

            guard let downloadURL else {
                Log.app.debug("UpdateChecker — no valid .zip download URL found for \(release.tagName)")
                return
            }

            guard let releasePageURL = URL(string: release.htmlURL) else {
                Log.app.debug("UpdateChecker — invalid htmlURL for \(release.tagName)")
                return
            }

            availableUpdate = AppUpdateInfo(
                version: release.tagName,
                releaseNotes: release.body ?? "",
                downloadURL: downloadURL,
                releasePageURL: releasePageURL
            )
            Log.app.info("UpdateChecker — update available: \(release.tagName)")
        } catch {
            Log.app.debug("UpdateChecker — check failed: \(error.localizedDescription)")
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
