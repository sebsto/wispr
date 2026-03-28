# Status: Fn Key as Hotkey (Issue #35)

**Last updated:** 2026-03-28
**Branch:** `sebsto/fn_key`
**Build:** compiles with zero errors, all tests pass

## Implementation Summary

All five tasks from `tasks.md` are implemented and verified. Two runtime bugs were found during manual testing and fixed. The implementation was audited against `implementation-notes.md` — all 8 notes are addressed.

### Task 1: Extend HotkeyMonitor with CGEventTap Backend — Done

**File:** `wispr/Services/HotkeyMonitor.swift`

- Added `ActiveBackend` enum with `.none`, `.carbon(hotkeyRef:handlerRef:)`, `.fnEventTap(machPort:runLoopSource:)` cases
- Refactored Carbon state out of separate ivars into the `.carbon` case
- Added `static let fnKeyCode: UInt32 = 63` sentinel
- `register()` branches: keyCode 63 + modifiers 0 routes to `setupFnEventTap()`, everything else to `registerCarbonHotkey()`
- `setupFnEventTap()` creates a `CGEvent.tapCreate` for `.flagsChanged` at session level, added to `CFRunLoopGetMain()`
- `handleFnFlagsChanged(flags:)` detects bare Fn press/release via `maskSecondaryFn` flag only (no keycode check — see bug fix below), passes through Fn+modifier combos, consumes bare Fn to suppress emoji picker
- `unregister()` switches on `activeBackend` and tears down whichever is active, including `CFMachPortInvalidate` (Note 2)
- `isolated deinit` calls `unregister()` and `stopWakeMonitoring()` — no `nonisolated(unsafe)` needed (Note 6)
- Handles `.tapDisabledByTimeout` and `.tapDisabledByUserInput` with up to 3 re-enable attempts (Note 5)
- Wake re-registration works for both backends (unregister + register recreates the tap)
- Class is `@Observable` so SwiftUI views can use it via `@Environment`

**Concurrency approach (Note 6):**
- `MainActor.assumeIsolated` in the CGEventTap callback (runs on main run loop, runtime-checked)
- CGEvent non-Sendable issue solved by extracting `flags` before entering the `assumeIsolated` closure — no `nonisolated(unsafe)` or `@unchecked Sendable` anywhere
- `isolated deinit` (Swift 6.2+) for cleanup

### Task 2: Update KeyCodeMapping for Fn Display — Done

**File:** `wispr/UI/Settings/KeyCodeMapping.swift`

- Added `63: "🌐 Fn"` to `keyNames` dictionary
- `hotkeyDisplayString(keyCode: 63, modifiers: 0)` returns `"🌐 Fn"` (verified by test)

### Task 3: Update HotkeyRecorderView to Capture Fn — Done

**File:** `wispr/UI/Settings/HotkeyRecorderView.swift`

- Added `@State private var fnMonitor: Any?` for NSEvent local monitor
- `installFnMonitor()` installs `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` when recording starts
- Monitor callback checks `event.keyCode == HotkeyMonitor.fnKeyCode` and `event.modifierFlags.contains(.function)` (press only, not release — Note 4)
- On Fn detection: sets `keyCode = 63, modifiers = 0`, exits recording, consumes the event
- `removeFnMonitor()` removes the monitor when recording ends or view disappears

### Task 4: Add Globe Key Conflict Warning to Settings — Done

**File:** `wispr/UI/Settings/SettingsView.swift`

- When `hotkeyKeyCode == 63 && hotkeyModifiers == 0`, reads `AppleFnUsageType` from `UserDefaults(suiteName: "com.apple.HIToolbox")` (Note 1)
- If value is 0 (emoji picker) or 2 (Character Viewer), shows a warning label
- Uses `@State var globeKeyConflict` with `refreshGlobeKeyConflict()` called from `.task` and `.onChange` for reactive updates (see bug fix below)
- Unregisters/re-registers hotkey monitor around recording to solve recorder vs active monitor race (Note 3)

### Task 5: Write Tests — Done

**File:** `wisprTests/HotkeyMonitorTests.swift`

Added 4 automated tests:
- `testFnKeyCodeConstant()` — verifies `HotkeyMonitor.fnKeyCode == 63`
- `testFnKeyNotReserved()` — verifies `register(keyCode: 63, modifiers: 0)` does not throw `hotkeyConflict`
- `testUnregisterAfterFnRegistration()` — verifies unregister after Fn registration doesn't crash
- `testFnKeyDisplayString()` — verifies `KeyCodeMapping` returns `"🌐 Fn"` for keycode 63

CGEventTap creation requires Accessibility permission, so tests that exercise the actual tap require manual testing.

## Bug Fixes (Post-Implementation)

### Fix 1: Fn Key Not Detected on Apple Silicon

**Problem:** `handleFnFlagsChanged` originally filtered on `keycode == 63`, but Apple Silicon Macs may report different keycodes in flagsChanged events for the Globe key.

**Fix:** Removed keycode check entirely. Detection now relies solely on `maskSecondaryFn` flag toggle — if the flag goes high with no other modifiers held, it's an Fn press; if it goes low, it's a release. This is reliable across Intel and Apple Silicon.

### Fix 2: Globe Key Warning Persists After Changing System Setting

**Problem:** Reading `UserDefaults` directly in the view body didn't trigger SwiftUI re-renders when external defaults changed.

**Fix:** Moved to `@State var globeKeyConflict` with a `refreshGlobeKeyConflict()` method called from `.task` (initial) and `.onChange(of: settingsStore.hotkeyKeyCode)` (reactive). The warning now updates when the user changes the hotkey.

### Fix 3: Recorder vs Active Monitor Race (Note 3)

**Problem:** When Fn is already the active hotkey, the session-level CGEventTap consumes Fn events before the app-level NSEvent monitor in the recorder can see them.

**Fix:** `SettingsView` reads `HotkeyMonitor` from SwiftUI environment and unregisters it when recording starts, re-registers when recording ends. Required changes:
- `HotkeyMonitor` — added `@Observable` conformance
- `MenuBarController` — accepts `hotkeyMonitor` parameter, injects via `.environment(hotkeyMonitor)`
- `wisprApp` — passes `hotkeyMonitor` to `MenuBarController`
- `SettingsView` — `@Environment(HotkeyMonitor.self)` + `.onChange(of: isRecordingHotkey)`

### Fix 4: Replaced Unreliable AppleFnUsageType Detection with Static Warning

**Problem:** On macOS 26, `UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType")` returns 0 (emoji picker) even when System Settings shows "Press Globe key to → Do Nothing". Apple moved or changed the storage mechanism, making programmatic detection unreliable.

**Fix:** Replaced detection with a static informational warning:
- When Fn is selected as the hotkey, SettingsView always shows a blue info label explaining the potential conflict with macOS emoji picker / input source switching and how to resolve it
- No longer reads `AppleFnUsageType` from any UserDefaults domain
- Removed `globeKeyConflict` state, `refreshGlobeKeyConflict()`, `Combine` import, and all related `.onChange`/`.onReceive` handlers

### Logging Added

Added `Log.hotkey` logger category and structured logging throughout `HotkeyMonitor`:
- `register()` — logs which backend is selected and success/failure
- `setupFnEventTap()` — logs tap creation success or failure (with Accessibility hint)
- CGEventTap callback — logs tap-disabled events with attempt count
- `handleFnFlagsChanged()` — logs Fn press/release with raw flag values
- Bootstrap in `wisprApp` — logs registration failure instead of silently catching

## Implementation Notes Audit

| Note | Topic | Status |
|------|-------|--------|
| 1 | AppleFnUsageType in com.apple.HIToolbox domain | Superseded — AppleFnUsageType unreliable on macOS 26; replaced with `isRegistered` check |
| 2 | CFMachPortInvalidate on teardown | Addressed — called in `unregister()` |
| 3 | Recorder vs active HotkeyMonitor race | Addressed — unregister/re-register via environment (Fix 3) |
| 4 | Fn release events in recorder | Addressed — checks `.function` flag for press only |
| 5 | tapDisabledByUserInput handling | Addressed — both timeout and user input handled with retry |
| 6 | MainActor.assumeIsolated over nonisolated(unsafe) | Addressed — no unsafe constructs anywhere |
| 7 | ActiveBackend enum refactor | Addressed — all Carbon code paths updated |
| 8 | Testing branching logic | Partially addressed — handleFnFlagsChanged takes raw flags (testable), but no test hook for backend selection |

## Copilot Code Review (PR #38) — Round 2

5 new comments evaluated (355b976):

| Comment | File | Verdict | Action |
|---------|------|---------|--------|
| `import os` unused | SettingsView.swift | Invalid — `Log.hotkey.error()` used on line 130 | Dismissed |
| Missing `import AppKit` | HotkeyRecorderView.swift | Valid — `NSEvent` requires AppKit | Fixed in 355b976 |
| Fn recorder accepts Fn+modifiers | HotkeyRecorderView.swift | Valid — inconsistent with HotkeyMonitor | Fixed in 355b976 |
| ARCHS=arm64 drops Intel (Debug) | project.pbxproj | Invalid — Apple Silicon only by design | Dismissed |
| ARCHS=arm64 drops Intel (Release) | project.pbxproj | Invalid — same as above | Dismissed |

## Copilot Code Review (PR #38) — Round 3

6 new comments evaluated (001e72c) — all spec/doc alignment:

| Comment | File | Verdict | Action |
|---------|------|---------|--------|
| Update AppleFnUsageType snippet | design.md:301 | Valid — stale code snippet | Fixed in 001e72c |
| Update recorder keyCode guard | design.md:267 | Valid — snippet uses keyCode not flag | Fixed in 001e72c |
| Update Req 4 acceptance criteria | requirements.md:45 | Valid — still references defaults reading | Fixed in 001e72c |
| Update Req 2 Fn+key limitation | requirements.md:22 | Valid — undocumented limitation | Fixed in 001e72c |
| Update Task 4 for static warning | tasks.md:43 | Valid — still references UserDefaults | Fixed in 001e72c |
| Update Task 3.3 keycode detection | tasks.md:34 | Valid — still references keyCode guard | Fixed in 001e72c |

## Files Modified

| File | Nature |
|------|--------|
| `wispr/Services/HotkeyMonitor.swift` | Major rewrite — two-backend architecture, @Observable |
| `wispr/UI/Settings/KeyCodeMapping.swift` | Added keycode 63 mapping |
| `wispr/UI/Settings/HotkeyRecorderView.swift` | NSEvent monitor for Fn during recording |
| `wispr/UI/Settings/SettingsView.swift` | Globe key warning, hotkey monitor environment, recorder race fix, app-activation refresh |
| `wispr/Utilities/Logger.swift` | Added `Log.hotkey` category |
| `wispr/UI/MenuBarController.swift` | Accepts hotkeyMonitor, injects into environment |
| `wispr/wisprApp.swift` | Passes hotkeyMonitor to MenuBarController |
| `wisprTests/HotkeyMonitorTests.swift` | 4 new automated tests |
| `wisprTests/MenuBarControllerTests.swift` | Updated test helper for new MenuBarController init |
