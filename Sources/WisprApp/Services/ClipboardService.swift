//
//  ClipboardService.swift
//  wispr
//
//  Thin abstraction over NSPasteboard to isolate AppKit clipboard access
//  to a single file. All other modules that need clipboard write access
//  call through this service instead of importing AppKit directly.
//

import AppKit

/// Provides clipboard operations backed by the system pasteboard.
///
/// This is the sole file that imports AppKit for general-purpose clipboard
/// access (outside of `TextInsertionService`, which has its own deeper
/// clipboard integration for paste-and-restore semantics).
@MainActor
enum ClipboardService {

    /// Copies a plain-text string to the system clipboard.
    ///
    /// - Parameter text: The string to place on the clipboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
