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
/// The GUI app (sandboxed) stores models under its container:
///   `~/Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr/`
///
/// The CLI (non-sandboxed) reads from the same container path so both
/// targets share a single set of downloaded models. Falls back to
/// `~/Library/Application Support/wispr/` only if the container doesn't exist.
///
/// WhisperKit appends its own `models/argmaxinc/whisperkit-coreml/<variant>/`
/// subtree beneath this root. FluidAudio's `AsrModels.downloadAndLoad(to:)`
/// and `DownloadUtils.downloadRepo(_:to:)` are given a base directory under
/// which they manage per-repo folders (for example,
/// `.../Application Support/wispr/models/parakeet-tdt-0.6b-v3`).
public nonisolated enum ModelPaths {

    /// Base directory shared by all model engines.
    ///
    /// Resolves to:
    /// - Sandboxed (GUI):     `~/Library/Containers/<bundle-id>/Data/Library/Application Support/wispr/`
    /// - Non-sandboxed (CLI): Same container path (preferred), or
    ///                        `~/Library/Application Support/wispr/` if container doesn't exist.
    public static var base: URL {
        // macOS sets APP_SANDBOX_CONTAINER_ID for sandboxed processes.
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        if isSandboxed {
            // Inside the sandbox (GUI app): FileManager automatically redirects
            // to ~/Library/Containers/<bundle-id>/Data/Library/Application Support/
            guard let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first else {
                fatalError("Application Support directory unavailable — cannot store models")
            }
            return appSupport.appendingPathComponent("wispr", isDirectory: true)
        }

        // Outside the sandbox (wispr-cli): read models from the GUI app's
        // sandbox container so the CLI finds models the GUI downloaded.
        let home = FileManager.default.homeDirectoryForCurrentUser
        let containerPath = home.appendingPathComponent(
            "Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr"
        )
        if FileManager.default.fileExists(atPath: containerPath.path) {
            return containerPath
        }

        // Container doesn't exist yet (GUI never launched). Fall back to the
        // standard Application Support path so the CLI can still start up,
        // though no models will be found until the GUI downloads them.
        guard let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            fatalError("Application Support directory unavailable — cannot store models")
        }
        return appSupport.appendingPathComponent("wispr", isDirectory: true)
    }

    /// The `models/` subdirectory under the base path.
    public static var models: URL {
        base.appendingPathComponent("models", isDirectory: true)
    }

    /// WhisperKit model repository: `<base>/models/argmaxinc/whisperkit-coreml/`
    public static var whisperModels: URL {
        models
            .appendingPathComponent("argmaxinc", isDirectory: true)
            .appendingPathComponent("whisperkit-coreml", isDirectory: true)
    }

    /// Parakeet V3 cache directory. Pass `AsrModels.defaultCacheDirectory(for: .v3).lastPathComponent` as sdkLeafName.
    public static func parakeetV3(sdkLeafName: String) -> URL {
        models.appendingPathComponent(sdkLeafName, isDirectory: true)
    }

    /// Parakeet EOU cache directory: `<base>/models/parakeet-eou-streaming/160ms/`
    public static var parakeetEou: URL {
        models
            .appendingPathComponent("parakeet-eou-streaming", isDirectory: true)
            .appendingPathComponent("160ms", isDirectory: true)
    }

    /// Parent directory for EOU model downloads.
    public static var parakeetEouParent: URL {
        models
    }

    /// URL of the GUI app's UserDefaults plist.
    /// Inside the sandbox this is the standard location; outside (CLI) it
    /// points into the GUI's container so the CLI reads current values
    /// rather than a stale `~/Library/Preferences/` copy.
    public static var guiDefaultsPlist: URL {
        let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
        if isSandboxed {
            guard let prefs = FileManager.default.urls(
                for: .libraryDirectory,
                in: .userDomainMask
            ).first?.appendingPathComponent("Preferences/com.stormacq.mac.wispr.plist") else {
                fatalError("Library directory unavailable")
            }
            return prefs
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(
            "Library/Containers/com.stormacq.mac.wispr/Data/Library/Preferences/com.stormacq.mac.wispr.plist"
        )
    }
}
