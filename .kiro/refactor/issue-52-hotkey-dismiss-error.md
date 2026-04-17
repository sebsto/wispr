# Issue #52 — Hotkey should dismiss error overlay and restart dictation

## Problem

When the user presses the hotkey and releases too quickly (no speech captured), the app enters `.error("No speech was detected...")` state with a 5-second auto-dismiss timer. During those 5 seconds, pressing the hotkey again is **silently ignored** — the user is blocked from starting a new dictation.

## Root Cause

Two guard conditions in `StateManager.swift` reject hotkey presses unless the app is in `.idle` state:

1. **`beginRecording()`** (push-to-talk mode): `guard appState == .idle else { return }`
2. **`toggleRecording()`** (hands-free mode): `case .error: break`

Both silently drop the hotkey event when the app is in `.error` state.

## Fix — 2 changes in `StateManager.swift`

### 1. `beginRecording()` — handle `.error` state before the guard

```swift
// Before the existing guard:
if case .error = appState {
    await resetToIdle()
}
guard appState == .idle else { ... }
```

`resetToIdle()` cancels the error dismiss timer, clears the error message, and sets state to `.idle`. The existing guard then passes and recording starts normally.

### 2. `toggleRecording()` — separate `.error` from `.loading`/`.processing`

```swift
case .error:
    await resetToIdle()
    await beginRecording()
case .loading, .processing:
    break
```

### No changes needed elsewhere

- **HotkeyMonitor** — already fires callbacks unconditionally regardless of app state
- **RecordingOverlayView** — already renders all states correctly (error → recording transition is seamless)
- **wisprApp overlay visibility** — driven by state, will show/hide automatically
- **resetToIdle()** — already cancels the error dismiss timer and clears state

## Testing

- [x] Add test: hotkey during `.error` state transitions to `.recording` (push-to-talk)
- [x] Add test: hotkey during `.error` state transitions to `.recording` (hands-free / toggle)
- [ ] Add test: error dismiss timer is cancelled when hotkey interrupts error state (not directly testable — `errorDismissTask` is private)
- [x] Verify existing tests still pass

## Implementation Summary

### Changes in `StateManager.swift`

1. **`beginRecording()`** — added `if case .error = appState { await resetToIdle() }` before the existing guard. Clears the error and lets recording proceed.
2. **`toggleRecording()`** — split `.error` out of `case .loading, .processing, .error: break` into its own case that calls `resetToIdle()` then `beginRecording()`.

### Tests updated in `StateManagerTests.swift`

1. **`testBeginRecordingDismissesError`** — replaced old `testConcurrentRecordingPreventionWhileError` that asserted error stays. Now verifies error is dismissed and `errorMessage` is cleared on hotkey press (push-to-talk).
2. **`testToggleRecordingDismissesError`** — new test verifying push-to-talk toggle path dismisses error.
3. **`testToggleRecordingDismissesErrorHandsFree`** — replaced old `testToggleRecordingIgnoredWhileError`. Now verifies hands-free toggle dismisses error.

All StateManager tests pass (0 failures).
