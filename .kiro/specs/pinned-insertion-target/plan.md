# Plan: Pinned Insertion Target

## Context

A user wants to "lock" a destination window for transcription output. Their use case: they take notes in an editor but navigate between emails and other docs while dictating. They want the transcription to always land in the initially chosen window, not whichever window is active at insertion time.

## Feasibility Analysis

### What macOS Allows (via Accessibility API)

| Operation | Works on background app? | Reliability |
|---|---|---|
| `AXUIElementCreateApplication(pid)` | Yes | High |
| Read `kAXWindowsAttribute` / `kAXFocusedUIElementAttribute` | Yes (returns last-focused element) | High |
| **Write** `kAXValueAttribute` on native Cocoa text field | Yes, even in background | Medium-High |
| Write on Electron apps (Slack, VS Code) | Generally not settable | Low |
| `CGEvent.postToPid()` for Cmd+V in background | Technically possible | Low (events often dropped) |
| `NSRunningApplication.activate()` + paste | Brief focus change | High |

### Verdict: Feasible, with nuances

**For native Cocoa apps** (TextEdit, Notes, Xcode, Terminal, etc.): `AXUIElementSetAttributeValue` works on a background element. The AXUIElement reference remains valid as long as the element exists.

**For Electron/web apps**: direct writing often fails. The fallback would be: briefly activate the target app (`NSRunningApplication.activate()`), paste via clipboard, then re-activate the previous app. This causes a visual flash of ~100-200ms.

## Recommended Approach: 2 Phases

### Phase 1 — Quick win: capture the target at recording start

**Current problem**: `TextInsertionService.insertViaAccessibility()` re-queries `kAXFocusedApplicationAttribute` at insertion time (after transcription). If the user has switched windows during transcription, text goes to the wrong window.

**Fix**: Capture the PID + AXUIElement of the focused text element at `beginRecording()` time, and pass them to `insertText()` after transcription.

- **Files to modify**:
  - `wispr/Services/TextInsertionService.swift` — add `captureTarget() -> InsertionTarget?` and `insertText(_:into:)`
  - `wispr/Services/StateManager.swift` — call `captureTarget()` in `beginRecording()`, store the target, pass it to `insertText()`

- **New type**:
  ```swift
  struct InsertionTarget {
      let pid: pid_t
      let appName: String
      let element: AXUIElement  // the text field that was focused
  }
  ```

- **Behavior**: if the captured target is no longer valid at insertion time (app closed, element destroyed), fall back to current behavior (active window).

### Phase 2 — Pinned window

**UX**: a button in the menu bar or settings allows pinning a target window. As long as it's pinned, all transcriptions go there.

**Sub-steps**:

1. **Window picker UI** — similar to Zoom's screen share picker:
   - Enumerate windows via `CGWindowListCopyWindowInfo` (no Screen Recording permission needed for titles on macOS 14+ if not using thumbnails)
   - Display: app name + window title
   - User clicks the desired window

2. **Store the pinned target**:
   - `SettingsStore`: `pinnedTargetPID: pid_t?`, `pinnedTargetWindowTitle: String?`
   - At insertion time, find the AXUIElement via PID + window matching

3. **Bridge CGWindowID -> AXUIElement**:
   - `AXUIElementCreateApplication(pid)` -> `kAXWindowsAttribute` -> match by title or frame
   - Find the text field via `kAXFocusedUIElementAttribute` on the app (returns last-focused element)

4. **Insertion strategy for pinned window**:
   - **Attempt 1**: direct AX write (`kAXValueAttribute`) on the background element
   - **Attempt 2**: if that fails, briefly activate the target app, paste, re-activate the previous app
   - **UI indicator**: menu bar icon showing a target is pinned + which app/window

5. **Unpin**: button in the menu bar, or automatically if the target window is closed

## Risks and Limitations

- **Electron apps**: direct background AX insertion will likely fail. The "activate + paste + re-activate" fallback will cause a visual flash.
- **Stale references**: the captured AXUIElement can become invalid (window closed, app crashed). Must always validate before insertion.
- **Multi-window apps**: `kAXFocusedUIElementAttribute` returns the last-focused element across the entire app, not per-window. May need to navigate the AX tree to find the right text field within a specific window.
- **Sandbox**: AX APIs already require Accessibility permission, which Wispr has. No additional entitlements needed.

## Verification

- Test direct AX insertion into a background TextEdit window (simplest case)
- Test with VS Code / Slack (Electron) to confirm fallback behavior
- Test that the AXUIElement reference survives a focus change
- Test the case where the target window is closed during recording

## Recommendation

Start with **Phase 1 only**. It's a small, safe change that already solves the main problem (window changes during transcription). Phase 2 (window picker + pinning) is a more ambitious feature that deserves its own implementation cycle.
