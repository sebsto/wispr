//
//  HotkeyMonitorTests.swift
//  wispr
//
//  Unit tests for HotkeyMonitor using swift-testing framework.
//  Focuses on testable logic: conflict detection, state management,
//  and callback setup. Carbon API registration requires a running
//  application event loop and cannot be tested in unit tests.
//

import Testing
import Foundation
@testable import WisprApp
import WisprCore

@MainActor
@Suite("HotkeyMonitor Tests")
struct HotkeyMonitorTests {

    // MARK: - Conflict Detection Tests

    @Test("register() throws hotkeyConflict for ⌘Space (Spotlight)")
    func testConflictCmdSpace() async {
        let monitor = HotkeyMonitor()
        // keyCode 49 = Space, modifiers 256 = ⌘ (cmdKey)
        #expect(throws: WisprError.hotkeyConflict(
            "The shortcut conflicts with a system-reserved shortcut."
        )) {
            try monitor.register(keyCode: 49, modifiers: 256)
        }
    }

    @Test("register() throws hotkeyConflict for ⌘⌥Space (Character Viewer)")
    func testConflictCmdOptSpace() async {
        let monitor = HotkeyMonitor()
        // keyCode 49 = Space, modifiers 4352 = ⌘⌥
        #expect(throws: WisprError.hotkeyConflict(
            "The shortcut conflicts with a system-reserved shortcut."
        )) {
            try monitor.register(keyCode: 49, modifiers: 4352)
        }
    }

    @Test("register() throws hotkeyConflict for ⌃Space (Input Sources)")
    func testConflictCtrlSpace() async {
        let monitor = HotkeyMonitor()
        // keyCode 49 = Space, modifiers 1280 = ⌃ (controlKey)
        #expect(throws: WisprError.hotkeyConflict(
            "The shortcut conflicts with a system-reserved shortcut."
        )) {
            try monitor.register(keyCode: 49, modifiers: 1280)
        }
    }

    @Test("register() does not throw conflict for non-reserved ⌥Space")
    func testNonReservedOptionSpace() async {
        let monitor = HotkeyMonitor()
        // keyCode 49 = Space, modifiers 2048 = ⌥ (optionKey)
        // This is the default Wispr hotkey — not system-reserved.
        // It will fail at Carbon registration (no app event target in tests)
        // but should NOT throw hotkeyConflict.
        do {
            try monitor.register(keyCode: 49, modifiers: 2048)
            // If Carbon works in test env, that's fine
        } catch let error as WisprError {
            // Should fail with registrationFailed, NOT conflict
            #expect(error == .hotkeyRegistrationFailed,
                    "Non-reserved shortcut should not throw hotkeyConflict")
        } catch {
            Issue.record("Unexpected non-WisprError thrown: \(error)")
        }
    }

    @Test("register() does not throw conflict for arbitrary key combo")
    func testNonReservedArbitraryCombo() async {
        let monitor = HotkeyMonitor()
        // keyCode 0 = 'A', modifiers 2048 = ⌥
        do {
            try monitor.register(keyCode: 0, modifiers: 2048)
        } catch let error as WisprError {
            #expect(error == .hotkeyRegistrationFailed,
                    "Arbitrary combo should not throw hotkeyConflict")
        } catch {
            Issue.record("Unexpected non-WisprError thrown: \(error)")
        }
    }

    // MARK: - Unregister / State Tests

    @Test("unregister() on fresh monitor does not crash")
    func testUnregisterFreshMonitor() async {
        let monitor = HotkeyMonitor()
        // Should be a no-op, no crash
        monitor.unregister()
    }

    @Test("unregister() can be called multiple times safely")
    func testDoubleUnregister() async {
        let monitor = HotkeyMonitor()
        monitor.unregister()
        monitor.unregister()
        // No crash = success
    }

    @Test("verifyRegistration() returns false when no hotkey is registered")
    func testVerifyRegistrationWhenUnregistered() async {
        let monitor = HotkeyMonitor()
        #expect(monitor.verifyRegistration() == false,
                "Should return false when no hotkey is registered")
    }

    @Test("verifyRegistration() returns false after unregister()")
    func testVerifyRegistrationAfterUnregister() async {
        let monitor = HotkeyMonitor()
        monitor.unregister()
        #expect(monitor.verifyRegistration() == false,
                "Should return false after explicit unregister")
    }

    // MARK: - Callback Setup Tests

    @Test("onHotkeyDown callback can be set and is initially nil")
    func testOnHotkeyDownInitiallyNil() async {
        let monitor = HotkeyMonitor()
        #expect(monitor.onHotkeyDown == nil, "onHotkeyDown should be nil initially")
    }

    @Test("onHotkeyUp callback can be set and is initially nil")
    func testOnHotkeyUpInitiallyNil() async {
        let monitor = HotkeyMonitor()
        #expect(monitor.onHotkeyUp == nil, "onHotkeyUp should be nil initially")
    }

    @Test("onHotkeyDown callback can be assigned")
    func testOnHotkeyDownAssignment() async {
        let monitor = HotkeyMonitor()
        var called = false
        monitor.onHotkeyDown = { called = true }
        // Invoke the callback directly to verify it was set
        monitor.onHotkeyDown?()
        #expect(called, "onHotkeyDown callback should be invocable after assignment")
    }

    @Test("onHotkeyUp callback can be assigned")
    func testOnHotkeyUpAssignment() async {
        let monitor = HotkeyMonitor()
        var called = false
        monitor.onHotkeyUp = { called = true }
        // Invoke the callback directly to verify it was set
        monitor.onHotkeyUp?()
        #expect(called, "onHotkeyUp callback should be invocable after assignment")
    }

    // MARK: - Fn Key Tests

    @Test("fnKeyCode constant is 63")
    func testFnKeyCodeConstant() async {
        #expect(HotkeyMonitor.fnKeyCode == 63)
    }

    @Test("register(keyCode: 63, modifiers: 0) does not throw conflict")
    func testFnKeyNotReserved() async {
        let monitor = HotkeyMonitor()
        // Fn key (63, 0) is not system-reserved.
        // It may fail with hotkeyRegistrationFailed (no Accessibility permission in CI)
        // but should NOT throw hotkeyConflict.
        do {
            try monitor.register(keyCode: 63, modifiers: 0)
        } catch let error as WisprError {
            #expect(error == .hotkeyRegistrationFailed,
                    "Fn key should not throw hotkeyConflict")
        } catch {
            Issue.record("Unexpected non-WisprError thrown: \(error)")
        }
    }

    @Test("unregister() after Fn registration does not crash")
    func testUnregisterAfterFnRegistration() async {
        let monitor = HotkeyMonitor()
        // Try to register Fn — may fail without Accessibility permission
        try? monitor.register(keyCode: 63, modifiers: 0)
        // Unregister should not crash regardless
        monitor.unregister()
    }

    @Test("KeyCodeMapping displays Fn key correctly")
    func testFnKeyDisplayString() async {
        let display = KeyCodeMapping.shared.hotkeyDisplayString(keyCode: 63, modifiers: 0)
        #expect(display == "🌐 Fn")
    }

    // MARK: - updateHotkey Conflict Detection Tests

    @Test("updateHotkey() throws hotkeyConflict for reserved shortcut")
    func testUpdateHotkeyConflict() async {
        let monitor = HotkeyMonitor()
        // Try to update to ⌘Space (reserved)
        #expect(throws: WisprError.hotkeyConflict(
            "The shortcut conflicts with a system-reserved shortcut."
        )) {
            try monitor.updateHotkey(keyCode: 49, modifiers: 256)
        }
    }

    @Test("updateHotkey() throws hotkeyConflict for ⌃Space")
    func testUpdateHotkeyConflictCtrlSpace() async {
        let monitor = HotkeyMonitor()
        #expect(throws: WisprError.hotkeyConflict(
            "The shortcut conflicts with a system-reserved shortcut."
        )) {
            try monitor.updateHotkey(keyCode: 49, modifiers: 1280)
        }
    }
}
