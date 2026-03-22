# Tasks: Fn Key as Hotkey (Issue #35)

## Task 1: Create FnKeyMonitor with CGEventTap
**Requirements:** 1, 6
**Files:** `wispr/Services/FnKeyMonitor.swift`

- [ ] 1.1 Create `FnKeyMonitor` as a `@MainActor final class`
- [ ] 1.2 Implement `start()` — create CGEventTap for `flagsChanged` events at session level
- [ ] 1.3 Implement C callback that detects bare Fn press/release (keycode 63, `maskSecondaryFn`)
- [ ] 1.4 Consume bare Fn events (return nil) to suppress emoji picker; pass through Fn+key combos
- [ ] 1.5 Implement `stop()` — remove tap from run loop, invalidate mach port
- [ ] 1.6 Implement `reregisterAfterWake()` — re-enable tap on system wake notification
- [ ] 1.7 Add tap health monitoring — detect disabled tap, re-enable up to 3 times, then fall back
- [ ] 1.8 Expose `onHotkeyDown` and `onHotkeyUp` callbacks matching `HotkeyMonitor` interface

## Task 2: Add SettingsStore Support
**Requirements:** 2
**Files:** `wispr/Services/SettingsStore.swift`

- [ ] 2.1 Add `useFnKeyHotkey: Bool` property with `didSet` persistence, default `false`
- [ ] 2.2 Add UserDefaults key constant
- [ ] 2.3 Add to `Defaults` enum, `load()`, `save()`, `restoreDefaults()`

## Task 3: Update Settings UI
**Requirements:** 3, 4
**Files:** `wispr/UI/Settings/SettingsView.swift`

- [ ] 3.1 Add mode selector (Picker or segmented control) for "Custom Hotkey" vs "Fn (Globe) Key"
- [ ] 3.2 Conditionally show/hide the hotkey recorder based on selected mode
- [ ] 3.3 Add Globe key conflict detection (read `AppleFnUsageType` from defaults)
- [ ] 3.4 Show non-blocking warning when conflict detected, with guidance to System Settings

## Task 4: Wire Up App Initialization
**Requirements:** 2, 5
**Files:** `wispr/wisprApp.swift`

- [ ] 4.1 Instantiate `FnKeyMonitor` alongside `HotkeyMonitor`
- [ ] 4.2 On app launch, activate the appropriate monitor based on `useFnKeyHotkey`
- [ ] 4.3 Wire `onHotkeyDown`/`onHotkeyUp` from the active monitor to `StateManager`
- [ ] 4.4 Observe `useFnKeyHotkey` setting changes and switch monitors at runtime
- [ ] 4.5 Ensure system wake re-registration works for both monitors

## Task 5: Write Tests
**Requirements:** 1, 2, 5, 6
**Files:** `wisprTests/FnKeyMonitorTests.swift`, `wisprTests/SettingsStoreTests.swift`

- [ ] 5.1 Test `FnKeyMonitor` start/stop lifecycle (no crash, clean teardown)
- [ ] 5.2 Test `FnKeyMonitor` callback assignment
- [ ] 5.3 Test `useFnKeyHotkey` setting persistence and defaults
- [ ] 5.4 Test mutual exclusivity — switching modes deactivates the other monitor
- [ ] 5.5 Test Globe key conflict detection with mocked `AppleFnUsageType` values
- [ ] 5.6 Manual test checklist: Fn detection, emoji suppression, Fn+F-key passthrough, wake recovery
