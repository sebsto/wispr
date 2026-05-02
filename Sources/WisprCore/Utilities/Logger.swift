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
public nonisolated enum Log {
    private static let subsystem = "com.stormacq.app.macos.wispr"

    public static let app = Logger(subsystem: subsystem, category: "App")
    public static let audioEngine = Logger(subsystem: subsystem, category: "AudioEngine")
    public static let whisperService = Logger(subsystem: subsystem, category: "WhisperService")
    public static let stateManager = Logger(subsystem: subsystem, category: "StateManager")
    public static let updateChecker = Logger(subsystem: subsystem, category: "UpdateChecker")
    public static let hotkey = Logger(subsystem: subsystem, category: "HotkeyMonitor")
    public static let textCorrection = Logger(subsystem: subsystem, category: "TextCorrection")
}
