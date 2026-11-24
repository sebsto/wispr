//
//  EnclosingAppBundle.swift
//  WisprCore
//
//  Makes the app bundle that contains the running executable visible to
//  Foundation's bundle registry.
//

import Foundation

public nonisolated enum EnclosingAppBundle {
    /// The `.app` bundle that contains `executable`, or `nil` when the
    /// executable does not live inside one.
    ///
    /// Symlinks are resolved first, so `/usr/local/bin/wispr` pointing into
    /// `Wispr.app/Contents/Resources/bin/WisprCLI` still finds `Wispr.app`.
    public static func url(containing executable: URL) -> URL? {
        var dir = executable.resolvingSymlinksInPath().deletingLastPathComponent()
        while dir.pathComponents.count > 1 {
            if dir.pathExtension == "app" { return dir }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Instantiates the enclosing app bundle so it appears in
    /// `Bundle.allBundles`.
    ///
    /// MLX locates its Metal library by scanning `Bundle.allBundles` for a
    /// `mlx-swift_Cmlx.bundle` inside each bundle's resources directory. The
    /// CLI is a bare executable in `Wispr.app/Contents/Resources/bin/`, so its
    /// main bundle is that directory and the scan never reaches
    /// `Wispr.app/Contents/Resources/mlx-swift_Cmlx.bundle`. Call this before
    /// the first MLX operation.
    @discardableResult
    public static func register(
        for executable: URL? = Bundle.main.executableURL
    ) -> Bundle? {
        guard let executable, let app = url(containing: executable) else { return nil }
        return Bundle(url: app)
    }
}
