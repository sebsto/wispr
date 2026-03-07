//
//  ModelPaths.swift
//  wispr
//
//  Single source of truth for the on-disk model storage root.
//  Both WhisperService and ParakeetService use this so every model
//  lives under the same Application Support directory.
//

import Foundation

/// Shared model storage paths.
///
/// All downloaded models (Whisper and Parakeet) are stored under:
///   `~/Library/Application Support/wispr/`
///
/// WhisperKit appends its own `models/argmaxinc/whisperkit-coreml/<variant>/`
/// subtree beneath this root. FluidAudio's `AsrModels.downloadAndLoad(to:)`
/// and `DownloadUtils.downloadRepo(_:to:)` are given a base directory under
/// which they manage per-repo folders (for example,
/// `.../Application Support/wispr/models/parakeet-tdt-v3`).
enum ModelPaths {

    /// Base directory shared by all model engines.
    ///
    /// Resolves to:
    /// - Sandboxed:     `~/Library/Containers/<bundle-id>/Data/Library/Application Support/wispr/`
    /// - Non-sandboxed: `~/Library/Application Support/wispr/`
    /// `nonisolated` because the project uses `@MainActor` as default isolation,
    /// but both WhisperService and ParakeetService (custom actors) need synchronous
    /// access. This is safe — the property is a pure computation with no mutable state.
    nonisolated static var base: URL {
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable — cannot store models")
        }
        return appSupport.appendingPathComponent("wispr", isDirectory: true)
    }
}
