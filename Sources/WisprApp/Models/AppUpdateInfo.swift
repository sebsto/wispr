//
//  AppUpdateInfo.swift
//  wispr
//
//  Describes an available app update from GitHub Releases.
//

import Foundation

struct AppUpdateInfo: Sendable, Equatable {
    let version: String
    let releaseNotes: String
    let downloadURL: URL
    let releasePageURL: URL
}
