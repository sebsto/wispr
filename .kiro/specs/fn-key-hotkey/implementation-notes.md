# Implementation Notes: Fn Key as Hotkey

Review notes and edge cases to address during implementation. These supplement the design doc.

## 1. AppleFnUsageType Lives in a Different UserDefaults Domain

The design doc shows `UserDefaults.standard.integer(forKey: "AppleFnUsageType")` but this key lives in the `com.apple.HIToolbox` domain, not the app's domain. Use:

```swift
UserDefaults(suiteName: "com.apple.HIToolbox")?.integer(forKey: "AppleFnUsageType")
```

Note: if the key is absent, `integer(forKey:)` returns 0, which is the "Emoji & Symbols" value — so a missing key correctly triggers the warning. But use `object(forKey:)` and nil-coalesce to 0 if you want to be explicit about the default.

## 2. CFMachPortInvalidate on Teardown

When tearing down the event tap, call `CFMachPortInvalidate(machPort)` after disabling the tap and removing the run loop source. Without this the mach port leaks. The design doc has been updated to include this, but double-check `deinit` also calls it.

## 3. Recorder vs Active HotkeyMonitor Race

If the Fn key is already the configured hotkey, the CGEventTap (global, session-level) will consume the Fn event before `NSEvent.addLocalMonitorForEvents` (local, app-level) sees it. Before entering recording mode, the caller must `unregister()` the active hotkey monitor — or the recorder will never detect Fn.

Check whether `HotkeyRecorderView` or `SettingsView` already unregisters the monitor when recording starts. If not, add this. Re-register when recording ends or is cancelled.

## 4. Fn Release Events in the Recorder

The `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` monitor fires on both Fn press AND release. The recorder must only accept the press (when `.function` flag is set), not the release. The design doc code sample handles this, but task 3.3 doesn't call it out explicitly — make sure the implementation checks `event.modifierFlags.contains(.function)` before accepting.

## 5. tapDisabledByUserInput

The original design only handled `.tapDisabledByTimeout`. The CGEventTap callback can also receive `.tapDisabledByUserInput`, which happens when the user revokes Accessibility permissions while the app is running. The design doc has been updated to handle both, using the same re-enable logic with a max retry count.

If re-enable fails (3 attempts exhausted), consider surfacing this to the user via the existing error path so they know to check Accessibility permissions or switch to a different hotkey.

## 6. Actor Isolation: Use MainActor.assumeIsolated, NOT nonisolated(unsafe)

The CGEventTap callback runs on `CFRunLoopGetMain()` — it's always on the main thread. The design uses `MainActor.assumeIsolated` inside the callback to re-enter actor isolation with a runtime assertion, rather than marking fields as `nonisolated(unsafe)`.

**Why `assumeIsolated` over `nonisolated(unsafe)`:**
- `nonisolated(unsafe)` is a "last resort" per Swift 6 guidance — it disables all compiler safety checks and requires a documented invariant + follow-up ticket to remove
- `assumeIsolated` validates the main-thread invariant at runtime (crashes if wrong — safe fail-fast)
- All fields (`fnIsDown`, `onHotkeyDown`, `onHotkeyUp`, `tapReEnableAttempts`) stay as regular `@MainActor`-isolated properties
- `handleFnFlagsChanged` stays as a regular isolated method, called from within the `assumeIsolated` closure
- No need to change `onHotkeyDown`/`onHotkeyUp` declarations

**Why NOT `Mutex`:** The state is only accessed from the main thread. A `Mutex` would add lock overhead for no safety benefit — the problem is isolation boundary crossing, not actual concurrent access.

**Existing Carbon path:** The Carbon callback also calls `handleCarbonEvent` (a `@MainActor` method) from a C function pointer. This compiles because C function pointer types bypass actor isolation checks. Consider adding `MainActor.assumeIsolated` to the Carbon callback too for consistency, as a separate cleanup.

## 7. ActiveBackend Enum Refactor Touches All Carbon Code

Task 1.2 moves `hotkeyRef` and `eventHandlerRef` from separate ivars into the `.carbon` case of `ActiveBackend`. This means every existing Carbon code path that reads or writes these properties must be updated. Audit:
- `register()` — sets `hotkeyRef`
- `unregister()` — reads and nils `hotkeyRef`, calls `removeEventHandler()`
- `installEventHandler()` — sets `eventHandlerRef`
- `removeEventHandler()` — reads and nils `eventHandlerRef`
- `verifyRegistration()` — checks `hotkeyRef != nil`
- `deinit` — reads both refs

Consider whether the refactor is worth it vs. keeping the existing ivars and adding new ivars for the event tap. The enum is cleaner but increases the blast radius of the change.

## 8. Testing the Branching Logic

CGEventTap can't be created in unit tests (no Accessibility permission in CI). To test the branching logic (`register` choosing Carbon vs event tap), consider:
- Extract `handleFnFlagsChanged` to take raw values (keycode: Int64, flags: CGEventFlags) instead of a `CGEvent`, so the filtering logic can be unit-tested
- Test that `register(keyCode: 63, modifiers: 0)` sets `activeBackend` to `.fnEventTap` (or at least doesn't set Carbon refs) — may need a `var isFnBackendActive: Bool` test hook
- The `KeyCodeMapping` test (task 5.5) is straightforward and should be automated
