# Requirements: Fn Key as Hotkey (Issue #35)

## Requirement 1: Fn Key as a Valid Hotkey Choice

**User Story:** As a user, I want to press the Fn (Globe) key during hotkey recording so it becomes my dictation trigger, just like any other key.

**Acceptance Criteria:**
- When the hotkey recorder is active and the user presses the bare Fn key, the recorder accepts it as keycode 63 with no modifiers.
- The Fn key is the only key that is accepted without a modifier (the existing modifier requirement is relaxed for keycode 63 only).
- The hotkey display shows "🌐 Fn" when the Fn key is configured.
- The Fn key hotkey is persisted in `SettingsStore` as `hotkeyKeyCode: 63, hotkeyModifiers: 0`, using the same fields as any other hotkey.
- No separate toggle, mode selector, or "Fn Key mode" is needed — it's just another hotkey the recorder can capture.

## Requirement 2: Fn Key Detection via CGEventTap

**User Story:** As a user, I want Fn key press/release to trigger recording start/stop so I can dictate with a single key.

**Acceptance Criteria:**
- When the configured hotkey is keycode 63 with modifiers 0, `HotkeyMonitor` internally uses a `CGEventTap` instead of Carbon's `RegisterEventHotKey`.
- The event tap intercepts `flagsChanged` events and detects Fn press (keycode 63, `CGEventFlags.maskSecondaryFn` set) and release (flag cleared).
- Bare Fn events are consumed (suppressed) to prevent the emoji/Character Viewer from opening.
- Fn combined with modifier keys (Fn+Cmd, Fn+Opt, etc.) is passed through unmodified.
- Note: bare Fn press/release events are consumed, which may affect some Fn-as-modifier combos (Fn+F1, Fn+Delete) — this is a known limitation documented in status.md.
- The event tap requires Accessibility permission (already granted for Wispr).

## Requirement 3: Unified HotkeyMonitor

**User Story:** As a developer, I want a single `HotkeyMonitor` class that handles both Carbon hotkeys and Fn key detection so the rest of the app doesn't need to know which mechanism is active.

**Acceptance Criteria:**
- `HotkeyMonitor` exposes the same public API regardless of which key is configured: `register()`, `unregister()`, `updateHotkey()`, `verifyRegistration()`, `reregisterAfterWake()`, `onHotkeyDown`, `onHotkeyUp`.
- When `register(keyCode: 63, modifiers: 0)` is called, `HotkeyMonitor` creates a CGEventTap internally instead of calling `RegisterEventHotKey`.
- When `register()` is called with any other keyCode/modifiers, `HotkeyMonitor` uses Carbon as today.
- `unregister()` tears down whichever mechanism is active (Carbon ref or event tap).
- `updateHotkey()` switches between Carbon and CGEventTap seamlessly when the key changes.
- `StateManager`, `wisprApp`, and all other callers require zero changes.

## Requirement 4: Globe/Emoji Picker Conflict Warning

**User Story:** As a user, I want Wispr to warn me if my system Globe key setting will conflict with Fn key dictation so I know how to fix it.

**Acceptance Criteria:**
- When the user records the Fn key as their hotkey, the Settings view shows a non-blocking, static informational message about potential Globe-key conflicts.
- The message provides guidance to change the Globe key behavior in System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing" to avoid conflicts with Fn-based dictation.
- The app does not read or display the current system Globe key setting (`AppleFnUsageType`); the message is purely instructional (on macOS 26 the value is unreliable).
- The informational message is shown when the Fn key is the configured hotkey and hidden for other hotkeys (appearing/disappearing when the hotkey is changed to/from Fn).

## Requirement 5: Event Tap Robustness

**User Story:** As a user, I don't want the Fn key feature to freeze my keyboard if something goes wrong.

**Acceptance Criteria:**
- The CGEventTap callback returns promptly (no blocking work) to avoid system-imposed timeouts.
- If the system disables the event tap, `HotkeyMonitor` detects this and re-enables it.
- If re-enabling fails after 3 attempts, `HotkeyMonitor` logs the failure and notifies via the existing error path. The user can switch to a different hotkey in Settings.
- System wake re-registration works for the CGEventTap path (re-enable the tap, same as Carbon re-registers).

## Requirement 6: Hotkey Recorder Fn Key Capture

**User Story:** As a developer, I need the hotkey recorder to detect Fn key presses so users can select it naturally.

**Acceptance Criteria:**
- `HotkeyRecorderView` detects Fn key presses during recording mode.
- Since SwiftUI's `.onKeyPress` does not receive Fn/Globe events, the recorder uses an `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)` to detect keycode 63.
- When Fn is detected, the recorder sets `keyCode = 63, modifiers = 0` and exits recording mode.
- The local event monitor is installed only while the recorder is active and removed when recording ends.
