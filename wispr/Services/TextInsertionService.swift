import Foundation
import AppKit
import ApplicationServices

/// Safely casts a `CFTypeRef` to `AXUIElement` after verifying its Core Foundation type ID.
private func castToAXUIElement(_ ref: CFTypeRef) -> AXUIElement? {
    guard CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    // swiftlint:disable:next force_cast
    return (ref as! AXUIElement)
}

/// Protocol for text insertion, enabling test mocking.
@MainActor
protocol TextInserting: Sendable {
    func insertText(_ text: String) async throws
}

/// Service responsible for inserting transcribed text at the cursor position.
///
/// Primary method: Accessibility API (AXUIElement)
/// Fallback method: Clipboard + simulated ⌘V keystroke
///
/// **Validates Requirements**: 4.1, 4.2, 4.3, 4.4, 4.5
///
/// Note: This is @MainActor isolated because NSPasteboard and CGEvent APIs
/// require main thread access.
@MainActor
final class TextInsertionService: TextInserting {
    
    // MARK: - Public Interface
    
    /// Inserts text at the current cursor position in the frontmost application.
    ///
    /// Attempts insertion via Accessibility API first. If that fails, falls back to
    /// clipboard-based insertion with pasteboard restoration.
    ///
    /// **Validates**: Requirement 4.1 (Accessibility API primary), 4.2 (clipboard fallback)
    ///
    /// - Parameter text: The text to insert
    /// - Throws: `WispError.textInsertionFailed` if both methods fail
    func insertText(_ text: String) async throws {
        // Try Accessibility API first (Requirement 4.1)
        do {
            try insertViaAccessibility(text)
            return
        } catch {
            // Accessibility failed, fall back to clipboard (Requirement 4.2)
            try await insertViaClipboard(text)
        }
    }
    
    // MARK: - Private Implementation
    
    /// Inserts text using macOS Accessibility APIs (AXUIElement).
    ///
    /// **Validates**: Requirement 4.1
    ///
    /// - Parameter text: The text to insert
    /// - Throws: `WispError.textInsertionFailed` if AX insertion fails
    private func insertViaAccessibility(_ text: String) throws {
        // Get the frontmost application
        let systemWideElement = AXUIElementCreateSystemWide()
        
        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWideElement,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        
        guard appResult == .success, let appElement = focusedApp else {
            throw WispError.textInsertionFailed("Could not get frontmost application")
        }
        
        // Safely cast to AXUIElement
        guard let appUIElement = castToAXUIElement(appElement) else {
            throw WispError.textInsertionFailed("Invalid application element type")
        }
        
        // Get the focused UI element within the app
        var focusedElement: CFTypeRef?
        let elementResult = AXUIElementCopyAttributeValue(
            appUIElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        
        guard elementResult == .success, let element = focusedElement else {
            throw WispError.textInsertionFailed("Could not get focused UI element")
        }
        
        // Safely cast to AXUIElement
        guard let focusedUIElement = castToAXUIElement(element) else {
            throw WispError.textInsertionFailed("Invalid focused element type")
        }
        
        // Check if the element supports text insertion
        var isSettable: DarwinBoolean = false
        let settableResult = AXUIElementIsAttributeSettable(
            focusedUIElement,
            kAXValueAttribute as CFString,
            &isSettable
        )
        
        guard settableResult == .success, isSettable.boolValue else {
            throw WispError.textInsertionFailed("Focused element does not support text insertion")
        }
        
        // Get current text value
        var currentValue: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            focusedUIElement,
            kAXValueAttribute as CFString,
            &currentValue
        )
        
        let currentText = (currentValue as? String) ?? ""
        
        // Get current selection range to insert at cursor position.
        // AX APIs report ranges in UTF-16 code units, so we must convert
        // to String.Index via the utf16 view to handle emoji / non-BMP text.
        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            focusedUIElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )
        
        let utf16View = currentText.utf16
        let utf16Offset: Int
        if rangeResult == .success,
           let range = selectedRange,
           CFGetTypeID(range) == AXValueGetTypeID() {
            // swiftlint:disable:next force_cast
            let axValue = range as! AXValue
            if AXValueGetType(axValue) == .cfRange {
                var cfRange = CFRange()
                if AXValueGetValue(axValue, .cfRange, &cfRange) {
                    utf16Offset = cfRange.location
                } else {
                    utf16Offset = utf16View.count
                }
            } else {
                utf16Offset = utf16View.count
            }
        } else {
            // If we can't get selection, append to end
            utf16Offset = utf16View.count
        }
        
        // Convert UTF-16 offset to String.Index safely
        let clampedOffset = min(utf16Offset, utf16View.count)
        let utf16Index = utf16View.index(utf16View.startIndex, offsetBy: clampedOffset)
        guard let stringIndex = String.Index(utf16Index, within: currentText) else {
            // Fallback: offset lands inside a surrogate pair — append to end
            let newText = currentText + text
            let insertResult = AXUIElementSetAttributeValue(
                focusedUIElement,
                kAXValueAttribute as CFString,
                newText as CFTypeRef
            )
            guard insertResult == .success else {
                throw WispError.textInsertionFailed("Failed to set text value via Accessibility API")
            }
            return
        }
        
        // Insert text at cursor position
        let newText = String(currentText[..<stringIndex]) + text + String(currentText[stringIndex...])
        
        let insertResult = AXUIElementSetAttributeValue(
            focusedUIElement,
            kAXValueAttribute as CFString,
            newText as CFTypeRef
        )
        
        guard insertResult == .success else {
            throw WispError.textInsertionFailed("Failed to set text value via Accessibility API")
        }
        
        // Move cursor to end of inserted text (UTF-16 offset for AX)
        var newRange = CFRange(location: clampedOffset + text.utf16.count, length: 0)
        if let rangeValue = AXValueCreate(.cfRange, &newRange) {
            AXUIElementSetAttributeValue(
                focusedUIElement,
                kAXSelectedTextRangeAttribute as CFString,
                rangeValue
            )
        }
    }
    
    /// Inserts text via clipboard by copying text and simulating ⌘V.
    ///
    /// **Validates**: Requirement 4.2 (clipboard fallback), 4.5 (restore pasteboard)
    ///
    /// - Parameter text: The text to insert
    /// - Throws: `WispError.textInsertionFailed` if clipboard insertion fails
    private func insertViaClipboard(_ text: String) async throws {
        let pasteboard = NSPasteboard.general
        
        // Save original pasteboard contents (Requirement 4.5)
        let originalContents = saveCurrentPasteboardContents(pasteboard)
        
        // Clear and set new text
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            throw WispError.textInsertionFailed("Failed to copy text to pasteboard")
        }
        
        // Simulate ⌘V keystroke
        let success = simulateCommandV()
        
        guard success else {
            throw WispError.textInsertionFailed("Failed to simulate ⌘V keystroke")
        }
        
        // Restore original pasteboard contents after 2 seconds (Requirement 4.5)
        await restorePasteboard(originalContents, after: .seconds(2))
    }
    
    /// Saves the current pasteboard contents for later restoration.
    ///
    /// - Parameter pasteboard: The pasteboard to save
    /// - Returns: Dictionary mapping types to data
    private func saveCurrentPasteboardContents(_ pasteboard: NSPasteboard) -> [NSPasteboard.PasteboardType: Data] {
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
    ///   - contents: The saved pasteboard contents
    ///   - delay: Duration to wait before restoring
    private func restorePasteboard(_ contents: [NSPasteboard.PasteboardType: Data], after delay: Duration) async {
        // Wait for the delay, but still restore even if cancelled
        do {
            try await Task.sleep(for: delay)
        } catch {
            // Even if cancelled, fall through to restore the pasteboard
        }
        
        guard !contents.isEmpty else { return }
        
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        
        for (type, data) in contents {
            pasteboard.setData(data, forType: type)
        }
    }
    
    /// Simulates a ⌘V keystroke using CGEvent.
    ///
    /// - Returns: `true` if the keystroke was successfully posted
    private func simulateCommandV() -> Bool {
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
