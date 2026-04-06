# Design: Pinned Insertion Target

## Feasibility Analysis

### What macOS Allows via Accessibility API

| Operation | Works on background app? | Reliability |
|---|---|---|
| `AXUIElementCreateApplication(pid)` | Yes | High |
| Read `kAXWindowsAttribute` | Yes | High |
| Read `kAXFocusedUIElementAttribute` on app | Yes (returns last-focused element) | High |
| Read `kAXValueAttribute` on text field | Yes | High |
| **Write** `kAXValueAttribute` on native Cocoa text field | **Yes, even in background** | Medium-High |
| Write `kAXValueAttribute` on Electron apps (VS Code, Slack) | Usually fails (not settable) | Low |
| `CGEvent.postToPid()` for Cmd+V to background app | Technically works | Low (events often dropped) |
| `NSRunningApplication.activate()` + clipboard paste | Requires brief focus change | High |
| `CGWindowListCopyWindowInfo` enumeration | N/A (system-wide) | High |

### Key Finding: AXUIElement References Survive Focus Changes

When you capture an `AXUIElement` reference to a text field while it has focus, that reference **remains valid and writable** after the user switches to another app. This is the foundation of the entire feature.

For native Cocoa apps (TextEdit, Notes, Xcode, Terminal, Safari text fields, etc.), calling `AXUIElementSetAttributeValue(element, kAXValueAttribute, newText)` works even when the element's app is in the background.

For Electron/web apps, the AX value attribute is typically not settable regardless of focus state. The existing clipboard fallback handles these apps but only works for the frontmost app.

### Verdict

**Phase 1 (Requirement 1) is straightforward and safe.** Capturing the AXUIElement at recording start and using it at insertion time is a small change to `TextInsertionService` and `StateManager`.

**Phase 2 (Requirements 2-3) is feasible but more complex.** The main challenges are:
- Bridging `CGWindowID` to `AXUIElement` (no direct API; requires PID + frame/title matching heuristic)
- Handling Electron apps where direct AX writing fails (fallback: briefly activate target app, paste, re-activate previous app — causes ~100-200ms visual flash)
- Keeping the pinned target valid when windows move, resize, or close

## Architecture

### Phase 1: Capture Target at Recording Start

**New type:**

```swift
struct InsertionTarget {
    let pid: pid_t
    let appName: String
    let element: AXUIElement
}
```

**TextInsertionService changes:**
- Add `captureTarget() -> InsertionTarget?` — queries the system-wide AX element for the current focused app and its focused text element. Returns nil if no settable text element is focused.
- Add `insertText(_:into:)` overload — uses the captured element directly instead of re-querying the focused app. Falls back to existing behavior if the captured element is stale.
- Extract the text-writing logic (read current value, compute cursor offset, write new value) into a shared `insertViaAccessibility(_:element:)` method.

**StateManager changes:**
- Add `private var insertionTarget: InsertionTarget?` property.
- In `beginRecording()`: call `textInsertionService.captureTarget()` before transitioning to `.recording`.
- In `insertTranscribedText()`: pass `insertionTarget` to `insertText(_:into:)`.
- In `resetToIdle()`: clear `insertionTarget`.

**Behavior when target is stale:**
- Before writing, validate the element with `AXUIElementIsAttributeSettable`. If it returns failure, discard the captured target and fall through to the existing "insert into frontmost app" logic.

### Phase 2: Pinned Window Mode (Future)

**Window enumeration:**
- Use `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)` to enumerate windows.
- Each entry provides `kCGWindowOwnerPID`, `kCGWindowOwnerName`, `kCGWindowName`, `kCGWindowBounds`.
- Note: window titles may require Screen Recording permission on macOS 14+ if using `kCGWindowName`. App names via `kCGWindowOwnerName` do not.

**CGWindowID to AXUIElement bridge:**
1. Get PID from `kCGWindowOwnerPID`
2. Create `AXUIElementCreateApplication(pid)`
3. Get `kAXWindowsAttribute` to enumerate AX windows
4. Match by title (`kAXTitleAttribute`) or frame (`kAXPositionAttribute` + `kAXSizeAttribute`)
5. Get `kAXFocusedUIElementAttribute` from the app (returns last-focused element)

**Insertion strategy for pinned target:**
1. **Try direct AX write** on the stored element (works for native Cocoa apps)
2. **Fallback: activate + paste + re-activate**
   - Save current frontmost app PID
   - `NSRunningApplication(processIdentifier: targetPID)?.activate()`
   - Wait ~100ms for the app to become key
   - Use existing clipboard insertion
   - Re-activate the previous app

**UI:**
- Menu bar submenu: "Pin Target Window" → opens window picker
- Menu bar indicator when pinned: "📌 TextEdit — notes.txt"
- "Unpin" action in menu bar
- Auto-unpin when target window closes (detect via AX notifications or periodic validation)

**SettingsStore:**
- `pinnedTargetPID: pid_t?` (not persisted across app launches — PIDs change)
- `pinnedTargetWindowTitle: String?` (for display only)

## Risks and Limitations

- **Electron/web apps**: Direct AX insertion in background fails. The activate+paste+re-activate fallback causes a brief visual flash (~100-200ms).
- **Stale references**: AXUIElement handles become invalid when the target element is destroyed (window closed, app quit). Must always validate before writing.
- **Multi-window apps**: `kAXFocusedUIElementAttribute` on the app returns the last-focused element across ALL windows, not per-window. For the pinned window feature, we may need to walk the AX tree to find text areas within a specific window.
- **Selection range staleness**: When writing to a background element, the cursor position (selection range) may be stale. For Phase 1 this is acceptable since the user was just typing there. For Phase 2, appending to end may be safer.
- **Sandbox**: All AX APIs used here only require Accessibility permission, which Wispr already has. No additional entitlements needed.
- **Screen Recording permission**: Only needed if we want to show window thumbnails in the picker (Phase 2). Not needed for titles or frame-matching.

## Recommendation

Implement **Phase 1 only** initially. It's a small, safe change (~50 lines across 2 files) that solves the core user problem: text going to the wrong window when the user switches apps during transcription.

Phase 2 (window picker + pinning) is a larger feature that should be prioritized based on user demand.

## Files to Modify (Phase 1)

- `wispr/Services/TextInsertionService.swift` — add `InsertionTarget`, `captureTarget()`, `insertText(_:into:)`, extract `insertViaAccessibility(_:element:)`
- `wispr/Services/StateManager.swift` — add `insertionTarget` property, capture in `beginRecording()`, pass in `insertTranscribedText()`, clear in `resetToIdle()`
