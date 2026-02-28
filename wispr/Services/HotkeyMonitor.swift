//
//  HotkeyMonitor.swift
//  wispr
//
//  Global hotkey registration using Carbon Event APIs.
//  Carbon is the only stable macOS API for system-wide hotkey registration.
//

import Carbon
import AppKit

/// Manages system-wide global hotkey registration using Carbon Event APIs.
///
/// This class must run on `@MainActor` because Carbon event handlers
/// dispatch on the main thread's run loop.
///
/// ## Why Carbon? (Modernization blocker)
/// Carbon's `RegisterEventHotKey` / `InstallEventHandler` is the only stable macOS API
/// for registering system-wide global hotkeys. Apple provides no AppKit, SwiftUI, or
/// modern replacement. Unblocked if Apple ships a `GlobalKeyboardShortcut` API or similar.
@MainActor
final class HotkeyMonitor {
    // MARK: - Callbacks

    /// Called when the registered hotkey is pressed down.
    var onHotkeyDown: (() -> Void)?

    /// Called when the registered hotkey is released.
    var onHotkeyUp: (() -> Void)?

    // MARK: - Private State

    /// Reference to the registered Carbon hotkey, nil when unregistered.
    /// nonisolated(unsafe) allows deinit cleanup. Safe because these are
    /// opaque pointers only accessed from main thread during normal operation.
    nonisolated(unsafe) private var hotkeyRef: EventHotKeyRef?

    /// The installed Carbon event handler reference.
    nonisolated(unsafe) private var eventHandlerRef: EventHandlerRef?

    /// Currently registered key code.
    private var registeredKeyCode: UInt32 = 0

    /// Currently registered modifier flags.
    private var registeredModifiers: UInt32 = 0

    /// Observer token for NSWorkspace.didWakeNotification.
    /// nonisolated(unsafe) allows deinit cleanup. Safe because the observer
    /// is only added/removed from the main actor.
    nonisolated(unsafe) private var wakeObserver: (any NSObjectProtocol)?

    /// Unique hotkey ID used to identify our hotkey in Carbon callbacks.
    private static let hotkeyID = EventHotKeyID(
        signature: OSType(0x5749_5350), // "WISP" in hex
        id: 1
    )

    // MARK: - System-Reserved Shortcuts

    /// Known system-reserved hotkey combinations that should not be registered.
    private static let reservedShortcuts: Set<String> = [
        "49-256",   // ⌘Space (Spotlight)
        "49-4352",  // ⌘⌥Space (Character Viewer)
        "49-1280",  // ⌃Space (Input Sources)
    ]

    // MARK: - Registration

    /// Registers a global hotkey with the given key code and modifier flags.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., 49 for Space).
    ///   - modifiers: Carbon modifier flags (e.g., optionKey = 2048).
    /// - Throws: `WispError.hotkeyConflict` if the combination is system-reserved,
    ///           `WispError.hotkeyRegistrationFailed` if Carbon registration fails.
    func register(keyCode: UInt32, modifiers: UInt32) throws {
        // Clean up any existing registration
        unregister()

        // Check for system-reserved conflicts
        let shortcutKey = "\(keyCode)-\(modifiers)"
        if Self.reservedShortcuts.contains(shortcutKey) {
            throw WispError.hotkeyConflict(
                "The shortcut conflicts with a system-reserved shortcut."
            )
        }

        // Install the Carbon event handler for hotkey events
        try installEventHandler()

        // Register the hotkey with Carbon
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            Self.hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard status == noErr, let ref = hotKeyRef else {
            removeEventHandler()
            throw WispError.hotkeyRegistrationFailed
        }

        self.hotkeyRef = ref
        self.registeredKeyCode = keyCode
        self.registeredModifiers = modifiers
    }

    /// Unregisters the current global hotkey and cleans up Carbon resources.
    func unregister() {
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
            hotkeyRef = nil
        }
        removeEventHandler()
        registeredKeyCode = 0
        registeredModifiers = 0
    }

    /// Updates the registered hotkey to a new combination.
    ///
    /// Unregisters the current hotkey and registers the new one.
    /// If the new registration fails, the previous hotkey remains unregistered.
    ///
    /// - Parameters:
    ///   - keyCode: The new virtual key code.
    ///   - modifiers: The new Carbon modifier flags.
    /// - Throws: `WispError.hotkeyConflict` or `WispError.hotkeyRegistrationFailed`.
    func updateHotkey(keyCode: UInt32, modifiers: UInt32) throws {
        let previousKeyCode = registeredKeyCode
        let previousModifiers = registeredModifiers

        unregister()

        do {
            try register(keyCode: keyCode, modifiers: modifiers)
        } catch {
            // Attempt to restore the previous hotkey if the new one fails
            if previousKeyCode != 0 {
                try? register(keyCode: previousKeyCode, modifiers: previousModifiers)
            }
            throw error
        }
    }

    /// Verifies that the hotkey is still registered and functional.
    ///
    /// Useful for post-sleep validation (Requirement 12.3).
    /// If the hotkey reference is stale, attempts to re-register.
    ///
    /// - Returns: `true` if the hotkey is currently registered and valid.
    func verifyRegistration() -> Bool {
        guard hotkeyRef != nil else { return false }
        guard registeredKeyCode != 0 else { return false }

        // Verify by attempting to re-register with the same parameters.
        // If the current registration is valid, unregister + re-register succeeds.
        let keyCode = registeredKeyCode
        let modifiers = registeredModifiers

        unregister()

        do {
            try register(keyCode: keyCode, modifiers: modifiers)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Wake Re-registration

    /// Listens for system wake notifications and re-registers the hotkey.
    ///
    /// Requirement 12.3: When the macOS system wakes from sleep, the HotkeyMonitor
    /// shall verify hotkey registration and re-register if necessary.
    ///
    /// Carbon hotkey registrations can become invalid after system sleep.
    /// This method installs an observer for `NSWorkspace.didWakeNotification`
    /// that automatically verifies and re-registers the hotkey on wake.
    func reregisterAfterWake() {
        // Remove any existing observer to avoid duplicates
        stopWakeMonitoring()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // We're on .main queue, and HotkeyMonitor is @MainActor,
            // so this closure runs on the main actor.
            Task { @MainActor in
                self.handleSystemWake()
            }
        }
    }

    /// Stops monitoring for system wake notifications.
    func stopWakeMonitoring() {
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            wakeObserver = nil
        }
    }

    /// Handles a system wake event by verifying and re-registering the hotkey.
    private func handleSystemWake() {
        let keyCode = registeredKeyCode
        let modifiers = registeredModifiers

        // Nothing to re-register if no hotkey was configured
        guard keyCode != 0 else { return }

        // Verify current registration; if invalid, re-register
        if !verifyRegistration() {
            // verifyRegistration already attempted re-registration and failed.
            // Try one more time as a last resort.
            try? register(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Carbon Event Handler

    /// Installs the Carbon event handler that listens for hotkey down/up events.
    private func installEventHandler() throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        // Store a raw pointer to self for the C callback.
        // This is safe because HotkeyMonitor is @MainActor and the Carbon
        // event handler also runs on the main thread.
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Carbon requires a C function pointer. We use a literal closure
        // that captures no context (only uses the userData parameter).
        let callback: EventHandlerUPP = { nextHandler, event, userData in
            guard let event = event, let userData = userData else {
                return OSStatus(eventNotHandledErr)
            }
            let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userData)
                .takeUnretainedValue()
            return monitor.handleCarbonEvent(event)
        }

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            callback,
            eventTypes.count,
            &eventTypes,
            selfPtr,
            &handlerRef
        )

        guard status == noErr, let ref = handlerRef else {
            throw WispError.hotkeyRegistrationFailed
        }

        self.eventHandlerRef = ref
    }

    /// Removes the installed Carbon event handler.
    private func removeEventHandler() {
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    /// Handles a Carbon hotkey event by dispatching to the appropriate closure.
    fileprivate func handleCarbonEvent(_ event: EventRef) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else { return status }
        guard hotKeyID.signature == Self.hotkeyID.signature,
              hotKeyID.id == Self.hotkeyID.id else {
            return OSStatus(eventNotHandledErr)
        }

        let eventKind = GetEventKind(event)
        switch Int(eventKind) {
        case kEventHotKeyPressed:
            onHotkeyDown?()
        case kEventHotKeyReleased:
            onHotkeyUp?()
        default:
            return OSStatus(eventNotHandledErr)
        }

        return noErr
    }

    deinit {
        // Note: deinit runs on whatever thread deallocates the object.
        // Since this is @MainActor, it should be the main thread.
        // Carbon cleanup is safe here because the refs are simple pointers.
        if let ref = hotkeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
        }
        if let observer = wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
    }
}


