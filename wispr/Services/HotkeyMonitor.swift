//
//  HotkeyMonitor.swift
//  wispr
//
//  Global hotkey registration using Carbon Event APIs or CGEventTap (for Fn key).
//  Carbon is the only stable macOS API for system-wide hotkey registration of
//  modifier+key combos. The Fn (Globe) key requires a CGEventTap on flagsChanged.
//

import Carbon
import AppKit
import CoreGraphics
import Observation
import os

/// Manages system-wide global hotkey registration.
///
/// Internally uses one of two backends:
/// - **Carbon** (`RegisterEventHotKey`) for standard modifier+key combos
/// - **CGEventTap** for the bare Fn/Globe key (keycode 63, no modifiers)
///
/// Callers interact with the same public API regardless of which backend is active.
@Observable
@MainActor
final class HotkeyMonitor {
    // MARK: - Callbacks

    /// Called when the registered hotkey is pressed down.
    var onHotkeyDown: (() -> Void)?

    /// Called when the registered hotkey is released.
    var onHotkeyUp: (() -> Void)?

    // MARK: - Constants

    /// Virtual key code for the Fn/Globe key.
    static let fnKeyCode: UInt32 = 63  // kVK_Function

    // MARK: - Registration Status

    /// Whether a hotkey backend is currently active and listening for key events.
    var isRegistered: Bool {
        switch activeBackend {
        case .none: false
        case .carbon, .fnEventTap: true
        }
    }

    // MARK: - Active Backend

    /// Which mechanism is currently intercepting key events.
    private enum ActiveBackend {
        case none
        case carbon(hotkeyRef: EventHotKeyRef, handlerRef: EventHandlerRef)
        case fnEventTap(machPort: CFMachPort, runLoopSource: CFRunLoopSource)
    }

    private var activeBackend: ActiveBackend = .none

    // MARK: - Private State

    /// Currently registered key code.
    private var registeredKeyCode: UInt32 = 0

    /// Currently registered modifier flags.
    private var registeredModifiers: UInt32 = 0

    /// Tracks whether the Fn key is currently held down (CGEventTap path only).
    private var fnIsDown = false

    /// Number of times we've tried to re-enable a disabled event tap.
    private var tapReEnableAttempts = 0

    /// Maximum re-enable attempts before giving up.
    private let maxTapReEnableAttempts = 3

    /// Observer token for NSWorkspace.didWakeNotification.
    private var wakeObserver: (any NSObjectProtocol)?

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
    /// For keyCode 63 (Fn/Globe) with no modifiers, uses a CGEventTap.
    /// For all other combinations, uses Carbon's RegisterEventHotKey.
    ///
    /// - Parameters:
    ///   - keyCode: The virtual key code (e.g., 49 for Space, 63 for Fn).
    ///   - modifiers: Carbon modifier flags (e.g., optionKey = 2048). Use 0 for Fn key.
    /// - Throws: `WisprError.hotkeyConflict` if the combination is system-reserved,
    ///           `WisprError.hotkeyRegistrationFailed` if registration fails.
    func register(keyCode: UInt32, modifiers: UInt32) throws {
        // Clean up any existing registration
        unregister()

        // Check for system-reserved conflicts
        let shortcutKey = "\(keyCode)-\(modifiers)"
        if Self.reservedShortcuts.contains(shortcutKey) {
            throw WisprError.hotkeyConflict(
                "The shortcut conflicts with a system-reserved shortcut."
            )
        }

        if keyCode == Self.fnKeyCode && modifiers == 0 {
            Log.hotkey.info("register — routing to CGEventTap backend for Fn key")
            try setupFnEventTap()
        } else {
            Log.hotkey.info("register — routing to Carbon backend for keyCode \(keyCode), modifiers \(modifiers)")
            try registerCarbonHotkey(keyCode: keyCode, modifiers: modifiers)
        }

        registeredKeyCode = keyCode
        registeredModifiers = modifiers
        Log.hotkey.info("register — succeeded for keyCode \(keyCode), modifiers \(modifiers)")
    }

    /// Unregisters the current global hotkey and cleans up resources.
    func unregister() {
        switch activeBackend {
        case .carbon(let hotkeyRef, let handlerRef):
            UnregisterEventHotKey(hotkeyRef)
            RemoveEventHandler(handlerRef)
        case .fnEventTap(let machPort, let runLoopSource):
            CGEvent.tapEnable(tap: machPort, enable: false)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            CFMachPortInvalidate(machPort)
        case .none:
            break
        }
        activeBackend = .none
        fnIsDown = false
        tapReEnableAttempts = 0
        registeredKeyCode = 0
        registeredModifiers = 0
    }

    /// Updates the registered hotkey to a new combination.
    ///
    /// Seamlessly switches between Carbon and CGEventTap backends as needed.
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
    func verifyRegistration() -> Bool {
        switch activeBackend {
        case .none:
            return false
        case .carbon, .fnEventTap:
            break
        }
        guard registeredKeyCode != 0 else { return false }

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
    func reregisterAfterWake() {
        stopWakeMonitoring()

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
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

        guard keyCode != 0 else { return }

        if !verifyRegistration() {
            try? register(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Carbon Backend

    /// Registers a hotkey using Carbon's RegisterEventHotKey.
    private func registerCarbonHotkey(keyCode: UInt32, modifiers: UInt32) throws {
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let callback: EventHandlerUPP = { nextHandler, event, userData in
            guard let event, let userData else {
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

        guard status == noErr, let handler = handlerRef else {
            throw WisprError.hotkeyRegistrationFailed
        }

        var hotKeyRef: EventHotKeyRef?
        let regStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            Self.hotkeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        guard regStatus == noErr, let ref = hotKeyRef else {
            RemoveEventHandler(handler)
            throw WisprError.hotkeyRegistrationFailed
        }

        activeBackend = .carbon(hotkeyRef: ref, handlerRef: handler)
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

    // MARK: - Fn/Globe CGEventTap Backend

    /// Creates a CGEventTap that intercepts flagsChanged events to detect Fn key.
    private func setupFnEventTap() throws {
        let eventMask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)

        // C callback — runs on main run loop. The callback executes synchronously
        // on the main thread since the run loop source is added to CFRunLoopGetMain.
        // We avoid crossing the MainActor isolation boundary with CGEvent by
        // extracting the data we need first and only entering the actor for state access.
        let callback: CGEventTapCallBack = { proxy, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }

            // Extract flags before entering actor isolation (CGEvent is not Sendable)
            let flags = event.flags
            let passthrough = Unmanaged.passUnretained(event)

            let consumed: Bool = MainActor.assumeIsolated {
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo)
                    .takeUnretainedValue()

                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    Log.hotkey.warning("CGEventTap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"), attempt \(monitor.tapReEnableAttempts + 1)")
                    monitor.tapReEnableAttempts += 1
                    if monitor.tapReEnableAttempts <= monitor.maxTapReEnableAttempts {
                        if case .fnEventTap(let port, _) = monitor.activeBackend {
                            CGEvent.tapEnable(tap: port, enable: true)
                        }
                    } else {
                        Log.hotkey.error("CGEventTap failed to re-enable after \(monitor.maxTapReEnableAttempts) attempts — unregistering Fn hotkey")
                        monitor.unregister()
                    }
                    return false
                }

                // Reset re-enable counter on successful callback
                monitor.tapReEnableAttempts = 0

                return monitor.handleFnFlagsChanged(flags: flags)
            }

            return consumed ? nil : passthrough
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            Log.hotkey.error("setupFnEventTap — CGEvent.tapCreate returned nil (missing Accessibility permission?)")
            throw WisprError.hotkeyRegistrationFailed
        }

        guard let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            Log.hotkey.error("setupFnEventTap — CFMachPortCreateRunLoopSource returned nil")
            CFMachPortInvalidate(tap)
            throw WisprError.hotkeyRegistrationFailed
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        activeBackend = .fnEventTap(machPort: tap, runLoopSource: source)
        Log.hotkey.info("setupFnEventTap — event tap created and enabled")
    }

    /// Processes a flagsChanged event looking for bare Fn press/release.
    ///
    /// Detects the Fn/Globe key by monitoring the `maskSecondaryFn` flag rather
    /// than relying on the keycode, because Apple Silicon Macs may report a
    /// keycode other than 63 in flagsChanged events for the Globe key.
    ///
    /// - Returns: `true` if the event should be consumed (suppressed), `false` to pass through.
    private func handleFnFlagsChanged(flags: CGEventFlags) -> Bool {
        // Pass through if other modifiers are held (Fn+Cmd, Fn+Opt, etc.)
        let otherModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        if !flags.intersection(otherModifiers).isEmpty {
            return false
        }

        let isFnDown = flags.contains(.maskSecondaryFn)

        if isFnDown && !self.fnIsDown {
            self.fnIsDown = true
            Log.hotkey.debug("handleFnFlagsChanged — Fn pressed (flags: \(flags.rawValue))")
            onHotkeyDown?()
            return true  // consume — suppress emoji picker
        } else if !isFnDown && self.fnIsDown {
            self.fnIsDown = false
            Log.hotkey.debug("handleFnFlagsChanged — Fn released (flags: \(flags.rawValue))")
            onHotkeyUp?()
            return true  // consume
        }

        return false
    }

    // MARK: - Cleanup

    isolated deinit {
        unregister()
        stopWakeMonitoring()
    }
}
