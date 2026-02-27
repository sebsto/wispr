//
//  DownloadProgress.swift
//  wispr
//
//  Created by Kiro
//

import Foundation

/// Progress information for model downloads
struct DownloadProgress: Sendable {
    let fractionCompleted: Double
    let bytesDownloaded: Int64
    let totalBytes: Int64
}
