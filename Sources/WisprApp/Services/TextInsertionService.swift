import WisprCore
import Foundation
import AppKit
import os

/// Protocol for text insertion, enabling test mocking.
@MainActor
protocol TextInserting: Sendable {
    func insertText(_ text: String) async throws
    func simulateEnterKey()
}

/// Minimal pasteboard surface used by the clipboard insertion path, so the
/// restore logic can be unit-tested with an in-memory fake instead of
/// `NSPasteboard.general`.
@MainActor
protocol TextPasteboard: AnyObject {
    var changeCount: Int { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
    @discardableResult func clearContents() -> Int
    @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool
    @discardableResult func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool
}

extension NSPasteboard: TextPasteboard {}

/// Service responsible for inserting transcribed text at the cursor position.
///
/// Method: Clipboard + simulated ⌘V keystroke.
///
/// The app runs under the App Sandbox (required for notarized/Developer ID and
/// App Store distribution), which prohibits using the Accessibility API
/// (`AXUIElement`) to read or control other apps' UI. Clipboard + ⌘V (via
/// `CGEvent`, which uses the separate PostEvent privilege) is therefore the only
/// viable way to insert text at the cursor in an arbitrary third-party app.
///
/// **Validates Requirements**: 4.2, 4.5
///
/// ## Privacy Guarantees (Requirement 11.4)
///
/// - **No logging or persistence**: Transcribed text received by `insertText(_:)`
///   is used solely for immediate insertion into the frontmost application. The text
///   is never logged, written to disk, cached, or transmitted over any network.
/// - **Clipboard restoration**: The original pasteboard contents are restored
///   within 2 seconds, ensuring the transcribed text does not linger on the
///   system clipboard.
/// - **No network connections**: This service uses only local macOS APIs
///   (NSPasteboard, CGEvent). No outbound network calls are made.
///
/// Note: This is @MainActor isolated because NSPasteboard and CGEvent APIs
/// require main thread access.
@MainActor
final class TextInsertionService: TextInserting {

    // MARK: - Pasteboard Restore State

    /// The user's original pasteboard contents captured before the first override.
    /// Remains set while a restore is pending, so rapid insertions don't re-capture
    /// our own transcription text as the "original".
    private var originalPasteboardContents: [NSPasteboard.PasteboardType: Data]?

    /// The pending pasteboard restore task. Cancelled and rescheduled on each insertion
    /// so the 2-second window resets.
    private var pasteboardRestoreTask: Task<Void, Never>?

    // MARK: - Injected Dependencies (production defaults)

    /// Pasteboard used to stage text for the ⌘V paste. Injectable for tests.
    private let pasteboard: any TextPasteboard

    /// Delay before the original pasteboard is restored after a paste.
    private let restoreDelay: Duration

    /// Performs the ⌘V paste. Injectable so tests don't post real key events.
    /// Returns `true` on success.
    private let performPaste: @MainActor () -> Bool

    // MARK: - Init

    init(
        pasteboard: any TextPasteboard = NSPasteboard.general,
        restoreDelay: Duration = .seconds(2),
        performPaste: (@MainActor () -> Bool)? = nil
    ) {
        self.pasteboard = pasteboard
        self.restoreDelay = restoreDelay
        // Default paste posts a real ⌘V; captured lazily to avoid referencing
        // `self` before initialization completes.
        self.performPaste = performPaste ?? { Self.postCommandV() }
    }

    // MARK: - Public Interface
    
    /// Inserts text at the current cursor position in the frontmost application
    /// via the clipboard + a simulated ⌘V keystroke, then restores the original
    /// clipboard.
    ///
    /// **Validates**: Requirement 4.2 (clipboard insertion)
    ///
    /// - Parameter text: The text to insert
    /// - Throws: `WisprError.textInsertionFailed` if insertion fails
    func insertText(_ text: String) async throws {
        try await insertViaClipboard(text)
    }

    // MARK: - Private Implementation

    /// Inserts text via clipboard by copying text and simulating ⌘V.
    ///
    /// **Validates**: Requirement 4.2 (clipboard insertion), 4.5 (restore pasteboard)
    ///
    /// - Parameter text: The text to insert
    /// - Throws: `WisprError.textInsertionFailed` if clipboard insertion fails
    private func insertViaClipboard(_ text: String) async throws {
        // Save the user's original pasteboard only if we don't already have a
        // pending override. This prevents capturing our own transcription text
        // when insertViaClipboard is called again before the restore fires.
        if originalPasteboardContents == nil {
            originalPasteboardContents = saveCurrentPasteboardContents(pasteboard)
        }

        // Clear and set new text
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw WisprError.textInsertionFailed("Failed to copy text to pasteboard")
        }

        // Snapshot the change count now that OUR transcription is staged on the
        // pasteboard, before we post ⌘V. If anything moves it before the restore
        // fires (e.g. the user copies something new), we must not clobber that.
        // (Bug: manual copy clobbered)
        let expectedChangeCount = pasteboard.changeCount

        // Log the overwrite without logging clipboard/transcription content
        // (privacy guarantee: transcribed text is never logged).
        Log.textInsertion.debug(
            "Clipboard overwritten with transcription (\(text.count, privacy: .public) chars) for ⌘V paste")

        // Simulate ⌘V keystroke
        let success = performPaste()

        guard success else {
            throw WisprError.textInsertionFailed("Failed to simulate ⌘V keystroke")
        }

        // Cancel any pending restore and reschedule, always restoring to the
        // original snapshot captured before the first override. (Requirement 4.5)
        let contentsToRestore = originalPasteboardContents ?? [:]
        pasteboardRestoreTask?.cancel()
        pasteboardRestoreTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restorePasteboard(
                contentsToRestore,
                after: self.restoreDelay,
                ifChangeCountIs: expectedChangeCount
            )
            // Only the currently-active restore clears shared state. A superseded
            // task (cancelled when a newer insertion rescheduled) must NOT nil these
            // out — doing so drops the handle to the live task and lets the next
            // insertion re-snapshot our own transcription as the "original".
            guard !Task.isCancelled else { return }
            self.originalPasteboardContents = nil
            self.pasteboardRestoreTask = nil
        }
    }

    /// Awaits the currently-scheduled pasteboard restore, if any. Test hook so a
    /// test can deterministically wait for the restore instead of sleeping.
    func awaitPendingPasteboardRestore() async {
        await pasteboardRestoreTask?.value
    }
    
    /// Saves the current pasteboard contents for later restoration.
    ///
    /// - Parameter pasteboard: The pasteboard to save
    /// - Returns: Dictionary mapping types to data
    private func saveCurrentPasteboardContents(_ pasteboard: any TextPasteboard) -> [NSPasteboard.PasteboardType: Data] {
        var contents: [NSPasteboard.PasteboardType: Data] = [:]
        
        for type in pasteboard.types ?? [] {
            if let data = pasteboard.data(forType: type) {
                contents[type] = data
            }
        }
        
        return contents
    }
    
    /// Restores pasteboard contents after a delay.
    ///
    /// **Validates**: Requirement 4.5 (restore within 2 seconds)
    ///
    /// - Parameters:
    ///   - contents: The saved pasteboard contents (may be empty if the user's
    ///     clipboard was empty before we overrode it).
    ///   - delay: Duration to wait before restoring.
    ///   - expectedChangeCount: The pasteboard `changeCount` captured right after
    ///     we placed our transcription. If the pasteboard has changed since (the
    ///     user copied something new), we leave it alone rather than clobbering
    ///     their copy.
    private func restorePasteboard(
        _ contents: [NSPasteboard.PasteboardType: Data],
        after delay: Duration,
        ifChangeCountIs expectedChangeCount: Int
    ) async {
        // Wait for the restore window. If we're cancelled, a newer insertion has
        // rescheduled and now owns the restore, so this superseded task must bow
        // out rather than touch the pasteboard or emit misleading logs.
        do {
            try await Task.sleep(for: delay)
        } catch {
            return
        }

        // If the user copied something after our paste, our transcription is no
        // longer on the clipboard — don't overwrite their new content.
        guard pasteboard.changeCount == expectedChangeCount else {
            Log.textInsertion.debug(
                "Clipboard changed since paste — skipping restore to preserve user's copy")
            return
        }

        // Clear our transcription unconditionally, then restore the original
        // contents. When the original was empty this leaves a clean clipboard
        // rather than letting the transcribed text linger.
        pasteboard.clearContents()

        for (type, data) in contents {
            pasteboard.setData(data, forType: type)
        }

        Log.textInsertion.debug(
            "Clipboard restored (\(contents.isEmpty ? "cleared — original was empty" : "original contents", privacy: .public))")
    }
    
    /// Simulates an Enter/Return keystroke using CGEvent.
    ///
    /// Called by StateManager when `autoSendEnterEnabled` is true.
    ///
    /// **Validates**: Requirement 5.6
    func simulateEnterKey() {
        // keyCode 0x24 = Return/Enter
        guard let keyDownEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x24,
            keyDown: true
        ) else {
            return
        }
        
        guard let keyUpEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x24,
            keyDown: false
        ) else {
            return
        }
        
        // Post events
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
    }
    
    /// Simulates a ⌘V keystroke using CGEvent.
    ///
    /// - Returns: `true` if the keystroke was successfully posted
    private static func postCommandV() -> Bool {
        // Create key down event for ⌘V
        guard let keyDownEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x09, // V key
            keyDown: true
        ) else {
            return false
        }
        
        // Set Command modifier
        keyDownEvent.flags = .maskCommand
        
        // Create key up event
        guard let keyUpEvent = CGEvent(
            keyboardEventSource: nil,
            virtualKey: 0x09, // V key
            keyDown: false
        ) else {
            return false
        }
        
        keyUpEvent.flags = .maskCommand
        
        // Post events
        keyDownEvent.post(tap: .cghidEventTap)
        keyUpEvent.post(tap: .cghidEventTap)
        
        return true
    }
}
