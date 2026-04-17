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

- [ ] Add test: hotkey during `.error` state transitions to `.recording` (push-to-talk)
- [ ] Add test: hotkey during `.error` state transitions to `.recording` (hands-free / toggle)
- [ ] Add test: error dismiss timer is cancelled when hotkey interrupts error state
- [ ] Verify existing tests still pass
