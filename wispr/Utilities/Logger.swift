//
//  Logger.swift
//  wispr
//
//  Structured logging via os.Logger.
//

import os

/// Centralized loggers for each subsystem category.
/// Use `Log.category.debug(...)` / `.info(...)` / `.error(...)` at call sites.
///
/// Logs are visible in Console.app and persist according to the os_log level:
/// - `.debug`: Not persisted by default, visible during debugging
/// - `.info`: Persisted during log collect
/// - `.error`: Persisted, visible in Console.app
nonisolated enum Log {
    private static let subsystem = "com.stormacq.app.macos.wispr"

    static let app = Logger(subsystem: subsystem, category: "App")
    static let audioEngine = Logger(subsystem: subsystem, category: "AudioEngine")
    static let whisperService = Logger(subsystem: subsystem, category: "WhisperService")
    static let stateManager = Logger(subsystem: subsystem, category: "StateManager")
}
