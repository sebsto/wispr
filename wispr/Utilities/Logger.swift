//
//  Logger.swift
//  wispr
//
//  Lightweight debug logging helper.
//

import Foundation

/// Logs a debug message to the console in DEBUG builds only.
///
/// Usage: `wispLog("AudioEngine", "startCapture — sample rate: \(rate)")`
///
/// In release builds this compiles to nothing thanks to `@inlinable`
/// and the `#if DEBUG` guard inside the function body.
@inlinable
nonisolated func wispLog(_ tag: String, _ message: @autoclosure () -> String) {
    #if DEBUG
    print("[Wisp:\(tag)] \(message())")
    #endif
}
