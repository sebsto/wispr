# Tasks: Fn Key as Hotkey (Issue #35)

## Task 1: Extend HotkeyMonitor with CGEventTap Backend
**Requirements:** 2, 3, 5
**Files:** `wispr/Services/HotkeyMonitor.swift`

- [ ] 1.1 Add `ActiveBackend` enum: `.none`, `.carbon(hotkeyRef, handlerRef)`, `.fnEventTap(machPort, runLoopSource)`
- [ ] 1.2 Refactor existing Carbon state (`hotkeyRef`, `eventHandlerRef`) into the `.carbon` case
- [ ] 1.3 Add `static let fnKeyCode: UInt32 = 63` sentinel constant
- [ ] 1.4 Branch in `register()`: if keyCode == 63 && modifiers == 0 → `setupFnEventTap()`, else → existing Carbon path
- [ ] 1.5 Implement `setupFnEventTap()`: create `CGEvent.tapCreate` for `.flagsChanged` at session level, add to main run loop
- [ ] 1.6 Implement `handleFnFlagsChanged(_:)`: detect bare Fn press/release (keycode 63, `maskSecondaryFn`), pass through Fn+key combos, consume bare Fn events
- [ ] 1.7 Implement `teardownFnEventTap()`: disable tap, remove run loop source
- [ ] 1.8 Update `unregister()` to switch on `activeBackend` and tear down the active one
- [ ] 1.9 Update `deinit` to clean up either backend
- [ ] 1.10 Handle `.tapDisabledByTimeout` in the callback: re-enable up to 3 times
- [ ] 1.11 Update `handleSystemWake()` / `reregisterAfterWake()` to work with the event tap path (unregister + register recreates the tap)

## Task 2: Update KeyCodeMapping for Fn Display
**Requirements:** 1
**Files:** `wispr/UI/Settings/KeyCodeMapping.swift`

- [ ] 2.1 Add `63: "🌐 Fn"` to `keyNames` dictionary
- [ ] 2.2 Verify `hotkeyDisplayString(keyCode: 63, modifiers: 0)` returns "🌐 Fn"

## Task 3: Update HotkeyRecorderView to Capture Fn
**Requirements:** 1, 6
**Files:** `wispr/UI/Settings/HotkeyRecorderView.swift`

- [ ] 3.1 Add `@State private var fnMonitor: Any?` for NSEvent local monitor
- [ ] 3.2 Install `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` when recording starts
- [ ] 3.3 In the monitor callback: if keycode == 63 and `.function` flag is set, accept as `keyCode = 63, modifiers = 0`, exit recording
- [ ] 3.4 Remove the monitor when recording ends (onChange of isRecording, or onDisappear)
- [ ] 3.5 No change needed to `handleKeyPress()` modifier guard — Fn is captured by NSEvent monitor, not `.onKeyPress`

## Task 4: Add Globe Key Conflict Warning to Settings
**Requirements:** 4
**Files:** `wispr/UI/Settings/SettingsView.swift`

- [ ] 4.1 When `hotkeyKeyCode == 63 && hotkeyModifiers == 0`, read `AppleFnUsageType` from UserDefaults
- [ ] 4.2 If value is 0 (emoji) or 2 (Character Viewer), show a warning label below the hotkey recorder
- [ ] 4.3 Warning text: guidance to change Globe key setting in System Settings → Keyboard
- [ ] 4.4 Warning appears/disappears reactively when hotkey changes to/from Fn

## Task 5: Write Tests
**Requirements:** 1, 2, 3, 5
**Files:** `wisprTests/HotkeyMonitorTests.swift`

- [ ] 5.1 Test that `register(keyCode: 63, modifiers: 0)` doesn't throw (event tap creation succeeds with Accessibility permission)
- [ ] 5.2 Test that `unregister()` after Fn registration doesn't crash
- [ ] 5.3 Test `updateHotkey()` switching from Carbon → Fn and Fn → Carbon
- [ ] 5.4 Test `verifyRegistration()` works for the Fn path
- [ ] 5.5 Test `KeyCodeMapping.shared.hotkeyDisplayString(keyCode: 63, modifiers: 0)` returns "🌐 Fn"
- [ ] 5.6 Manual test checklist: Fn press/release detection, emoji picker suppression, Fn+F-key passthrough, wake recovery, switching hotkeys at runtime
