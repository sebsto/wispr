# Requirements: Fn Key as Hotkey (Issue #35)

## Requirement 1: Fn Key Detection via CGEventTap

**User Story:** As a user, I want to use the Fn (Globe) key to trigger voice dictation so I can start/stop recording with a single convenient key press.

**Acceptance Criteria:**
- A new `FnKeyMonitor` class can detect Fn key press and release events system-wide.
- `FnKeyMonitor` uses `CGEventTap` to intercept `flagsChanged` events for keycode 63 (`kVK_Function`).
- Fn press events are detected when `CGEventFlags.maskSecondaryFn` appears in the flags.
- Fn release events are detected when `CGEventFlags.maskSecondaryFn` disappears from the flags.
- The event tap consumes bare Fn press/release events (returns `nil`) to suppress the emoji/Character Viewer picker.
- Fn key combined with other keys (Fn+F1, Fn+F2, etc.) is passed through unmodified so standard F-key behavior is preserved.
- `FnKeyMonitor` requires Accessibility permission (already granted for Wispr's existing functionality).

## Requirement 2: Fn Key Hotkey Mode Setting

**User Story:** As a user, I want to choose the Fn key as my dictation trigger in Settings so I don't need a modifier+key combination.

**Acceptance Criteria:**
- A `useFnKeyHotkey: Bool` setting exists in `SettingsStore`, defaulting to `false`.
- The setting persists across app launches via UserDefaults.
- When `useFnKeyHotkey` is `true`, `FnKeyMonitor` is activated and `HotkeyMonitor` is deactivated.
- When `useFnKeyHotkey` is `false`, `HotkeyMonitor` is used as today and `FnKeyMonitor` is inactive.
- Changing the setting takes effect immediately without requiring an app restart.
- Restoring defaults resets `useFnKeyHotkey` to `false`.

## Requirement 3: Settings UI for Fn Key Option

**User Story:** As a user, I want a clear option in Settings to enable Fn key mode so I can easily switch between Fn key and custom hotkey modes.

**Acceptance Criteria:**
- The Hotkey section of SettingsView shows a toggle or segmented control to choose between "Custom Hotkey" and "Fn Key".
- When "Fn Key" is selected, the hotkey recorder control is hidden or disabled (since it's not needed).
- When "Custom Hotkey" is selected, the existing hotkey recorder is shown as today.
- The Fn key option includes an accessibility label and hint describing its behavior.

## Requirement 4: Globe/Emoji Picker Conflict Detection

**User Story:** As a user, I want Wispr to warn me if my system Globe key setting conflicts with Fn key dictation so I know how to fix it.

**Acceptance Criteria:**
- When Fn key mode is activated, Wispr checks the system's Globe key setting (`AppleFnUsageType` in `com.apple.HIToolbox` defaults).
- If the Globe key is configured to open the emoji picker or Character Viewer (value 0 or 2), Wispr displays a non-blocking warning with a link/instructions to change the setting in System Settings → Keyboard → "Press 🌐 key to" → "Do Nothing".
- If the Globe key is already set to "Do Nothing" (value 1) or "Change Input Source" (value 3), no warning is shown.
- The warning is shown once per activation (not on every recording attempt).

## Requirement 5: Coexistence with Existing Hotkey System

**User Story:** As a developer, I need the Fn key monitor to coexist cleanly with the existing Carbon hotkey system so switching between modes is reliable.

**Acceptance Criteria:**
- `FnKeyMonitor` and `HotkeyMonitor` are mutually exclusive at runtime — only one is active at a time.
- Both monitors expose the same callback interface (`onHotkeyDown`, `onHotkeyUp`) so `StateManager` doesn't need to know which is active.
- Switching from Fn key mode to custom hotkey mode (or vice versa) properly tears down the outgoing monitor before activating the incoming one.
- System wake re-registration works for both monitors (Carbon re-registers hotkey; CGEventTap re-enables the tap).
- Push-to-talk and hands-free dictation modes both work with Fn key mode (Fn press/release maps to the same down/up events).

## Requirement 6: Event Tap Robustness

**User Story:** As a user, I don't want the Fn key feature to freeze my keyboard if something goes wrong.

**Acceptance Criteria:**
- The CGEventTap is created as an active tap (`kCGEventTapOptionDefault`) to consume Fn events.
- If the system disables the event tap (due to timeout), `FnKeyMonitor` detects this and re-enables it.
- If re-enabling fails after 3 attempts, `FnKeyMonitor` falls back to the standard `HotkeyMonitor` and notifies the user via the error state.
- The event tap callback returns promptly (no blocking work) to avoid system-imposed timeouts.
