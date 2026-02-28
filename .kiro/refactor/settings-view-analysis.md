read .kiro for spec and context. Use the swiftui expert skill.  I want you to refactor SwiftUI SettingsView.swift file. Follow the recommendation of .kiro/refactor/settings-view-analysis.md. Don't follow it blindly - apply judgment and challenge some proposal if you think they don't make sense. Do not touch any other file, unless creating files to split code. In that case, put all the settings related code in the same subdirectory (to be created). do not commit code. Make a pause between major changes to let me validate manually. Use subagent as much as possible.

# SettingsView Refactoring Analysis

**File:** `SettingsView.swift`
**Date:** 2025
**Scope:** Code quality, modern Swift patterns, UX, Apple Human Interface Guidelines (HIG)

---

## 1. Architecture & Code Organization

### 1.1 — SupportedLanguage should not live in the view file
The `SupportedLanguage` struct with its 97-entry static array is a data model concern, not a view concern. It inflates `SettingsView.swift` to ~370 lines and makes it harder to locate actual UI code. This type should be extracted into its own file (e.g., `SupportedLanguage.swift` in the Models group).

### 1.2 — HotkeyRecorderView should be its own file
`HotkeyRecorderView` is a self-contained, reusable control (~120 lines) with its own state, key mapping dictionaries, and display logic. Embedding it in `SettingsView.swift` violates single-responsibility and makes both components harder to test and maintain. It should live in its own file.

### 1.3 — Duplicated key-code dictionaries
`HotkeyRecorderView` contains two near-identical `[Character: UInt32]` / `[UInt32: String]` dictionaries (`virtualKeyCode(from:)` and `keyCodeToString(_:)`). These should be unified into a single bidirectional mapping, ideally in a shared utility (e.g., `KeyCodeMapping`), to eliminate the risk of them drifting out of sync.

### 1.4 — `scrollDisabled(true)` with `fixedSize` is fragile
The combination of `.scrollDisabled(true)` and `.fixedSize(horizontal: false, vertical: true)` forces the form to expand to its intrinsic height. If more sections or longer picker lists are added, content will be clipped with no way to scroll. A max height constraint with scrolling enabled would be more resilient.

---

## 2. Modern Swift & SwiftUI Patterns

### 2.1 — Inconsistent `@Bindable` usage
The view accesses `settingsStore` via `@Environment` and creates `@Bindable var store = settingsStore` inline inside some section bodies (e.g., `audioDeviceSection`, `generalSection`) but uses manual `Binding` wrappers in the language section. The manual bindings for `autoDetectBinding`, `selectedLanguageCodeBinding`, and `pinLanguageBinding` are justified because they perform side-effect logic, but the pattern should be documented with a comment explaining *why* manual bindings are used there versus `@Bindable` elsewhere, for maintainability.

### 2.2 — `init` injects services but view reads `@Environment` for stores
`SettingsView` receives `AudioEngine` and `WhisperService` through its initializer but reads `SettingsStore` and `UIThemeEngine` from `@Environment`. This hybrid dependency injection pattern is inconsistent. Consider either:
- Moving all dependencies to `@Environment`, or
- Passing all dependencies through `init`.

Using `@Environment` for all would be the more idiomatic SwiftUI approach, especially since `AudioEngine` and `WhisperService` are actors that could be placed in the environment.

### 2.3 — `.task` loads data once with no refresh mechanism
`loadAudioDevices()` and `loadWhisperModels()` are called once in `.task`. If a user plugs in a USB microphone while the settings window is open, the device list won't update. Consider using `.task(id:)` with a trigger, or observing device change notifications, to refresh the lists dynamically. `AudioEngine` already has `startDeviceMonitoring()` infrastructure for this.

### 2.4 — Model validation on selection uses `onChange` with eager fallback
The `onChange(of: settingsStore.activeModelName)` modifier immediately reverts to a fallback model if the selected model isn't downloaded. This is correct defensively, but creates a jarring UX — the picker briefly shows the invalid selection, then snaps back. A better approach is to disable non-downloaded items in the picker entirely (currently they're only visually dimmed with `opacity(0.4)` but remain selectable).

### 2.5 — Missing `Equatable` on `SupportedLanguage`
`SupportedLanguage` conforms to `Identifiable` and `Sendable` but not `Equatable` or `Hashable`. Since it's used in `ForEach` and as a tag source, adding `Hashable` conformance would be good practice and enable future use in `Set` or dictionary keys.

---

## 3. Apple Human Interface Guidelines (HIG)

### 3.1 — Settings window should use `Settings` scene (macOS)
On macOS, the idiomatic way to present settings is via a `Settings` scene in the `App` body, which automatically integrates with the app menu's "Settings…" item (⌘,). If this view is presented as a standalone window instead of a `Settings` scene, it misses standard macOS behaviors like the window title, toolbar style, and menu integration.

### 3.2 — Fixed width of 520pt may not accommodate all localizations
The hard-coded `.frame(width: 520)` doesn't account for languages with longer labels (e.g., German, Finnish). Apple HIG recommends allowing settings windows to adapt to content width. Consider using a minimum width with flexible sizing, or at least testing with pseudo-localization.

### 3.3 — Non-downloaded models should be non-interactive, not just dimmed
Per HIG, items that cannot be selected should be clearly disabled, not just visually faded. The `.opacity(0.4)` on non-downloaded models makes them look disabled but they are still tappable. The picker should either:
- Use `.disabled(true)` on those items (though `Picker` doesn't support per-item disabling), or
- Filter them out and show a "Download more models…" link, or
- Show a sheet/alert when a non-downloaded model is selected, explaining it needs to be downloaded first.

### 3.4 — Hotkey recorder lacks clear escape hatch
When `isRecording` is true, the only way to cancel is to click the button again. HIG recommends that Escape cancels modal interactions. The `onKeyPress` handler should check for Escape and cancel recording without changing the hotkey. Currently, pressing Escape while recording will fail the modifier check and show an error message, which is confusing.

### 3.5 — Section headers use custom styling instead of native Form headers
The `SectionHeader` view applies custom font and icon styling. While visually appealing, macOS `Form` with `.formStyle(.grouped)` already provides a standard header appearance. The custom headers may conflict with future system styling changes (e.g., Liquid Glass updates). Consider whether the custom styling is truly necessary or if native section headers would be more future-proof and consistent.

### 3.6 — No "Restore Defaults" option
HIG recommends providing a way to reset preferences to their defaults. There is no reset/restore button in any section. Consider adding a "Restore Defaults" button, at minimum in the General section.

---

## 4. UX Concerns

### 4.1 — Language picker shows 97 languages in a flat list
Scrolling through 97 languages in a `Picker` is a poor experience. Consider:
- Grouping by script or region with section headers.
- Adding a search/filter field (a `Picker` with `.pickerStyle(.menu)` shows all items in a long menu; a `List` with a search field would be better for this many items).
- Showing recently used or common languages at the top.

### 4.2 — "Pin Language" concept is unclear
The distinction between selecting a language and "pinning" it is not self-evident. The accessibility hint says "locks transcription to the selected language," but the user might not understand what that means versus simply having a language selected. Consider:
- A more descriptive label like "Always use this language (skip auto-detection)."
- A brief inline description or footer text explaining the behavior.

### 4.3 — No feedback when audio devices or models fail to load
`loadAudioDevices()` and `loadWhisperModels()` silently produce empty arrays on failure. The user would see empty pickers with no explanation. Consider showing an inline message like "No audio devices found" or "Unable to load models" when the arrays are empty after loading.

### 4.4 — Model picker doesn't show which model is currently active
The picker uses `settingsStore.activeModelName` as the selection, but the model list from `WhisperService` has an `.active` status that could be visualized (e.g., a checkmark badge). The `status` property is available but only used for download-state gating. Showing the active model explicitly would help users understand the current state.

### 4.5 — Hotkey error message is transient but never auto-dismissed
If the user triggers a hotkey error (e.g., no modifier key), the error stays visible indefinitely until they successfully record a new hotkey or toggle recording off. Consider auto-dismissing after a few seconds, or making it a more clearly styled inline error with a dismiss button.

---

## 5. Accessibility

### 5.1 — Picker accessibility hints are generic
Hints like "Select the microphone to use for recording" are good, but the pickers themselves don't announce the current selection. VoiceOver users would benefit from `accessibilityValue` being set on the containing `LabeledContent` or `Picker` to announce the currently selected item name.

### 5.2 — Language section animation may be disorienting
The `.animation(.smooth, value: settingsStore.languageMode.isAutoDetect)` animates the appearance/disappearance of the language picker and pin toggle. This does not check `UIThemeEngine.reduceMotion`. The codebase has `motionRespectingAnimation(value:)` — it should be used here instead of raw `.animation(.smooth, ...)`.

### 5.3 — Hotkey section animation also doesn't respect Reduce Motion
`.animation(.smooth, value: hotkeyError)` has the same issue as §5.2. Should use the theme engine's motion-respecting animation.

### 5.4 — `HotkeyRecorderView` hover effect doesn't respect Reduce Motion
The `.scaleEffect(isHovering ? 1.02 : 1.0)` animation runs regardless of Reduce Motion preferences. It should be conditional on `theme.reduceMotion`.

### 5.5 — Missing accessibility for non-downloaded model state
Models that are not downloaded show "— Not Downloaded" visually but this information isn't conveyed to assistive technologies. The picker items should include this status in their `accessibilityLabel`.

---

## 6. Performance & Correctness

### 6.1 — `loadWhisperModels()` calls `modelStatus` sequentially for each model
The function loops over models and calls `await whisperService.modelStatus(model.id)` one at a time. Since `WhisperService` is an actor, each call involves an actor hop. These could be batched or parallelized with `TaskGroup`, though the practical impact is small with only 5 models.

### 6.2 — `virtualKeyCode(from:)` falls back to Space (49) silently
If `keyPress.characters` contains a character not in the key map (e.g., a non-Latin character from an alternative keyboard layout), the function silently maps it to Space. This could lead to the user unknowingly setting their hotkey to Space. The function should either return an optional and show an error, or use `keyPress`'s underlying key equivalent for better coverage.

### 6.3 — Carbon modifier constants may differ from SwiftUI modifier representation
The code converts `KeyPress.modifiers` (SwiftUI `EventModifiers`) to Carbon modifier flags (`cmdKey`, `optionKey`, etc.). These Carbon constants are legacy and their integer values are not guaranteed to remain stable across macOS versions (though they have been stable historically). Consider documenting this assumption or using a more modern approach if one becomes available.

### 6.4 — No debounce on `settingsStore` saves
Every property change on `SettingsStore` triggers a full `save()` call to `UserDefaults`. When the user adjusts multiple settings in quick succession, this causes redundant I/O. A debounced save (e.g., coalescing saves within 500ms) would be more efficient.

---

## 7. Summary of Recommended Actions

| Priority | Item | Section |
|----------|------|---------|
| **High** | Extract `SupportedLanguage` to its own file | §1.1 |
| **High** | Extract `HotkeyRecorderView` to its own file | §1.2 |
| **High** | Disable or gate non-downloaded models in picker | §3.3, §2.4 |
| **High** | Handle Escape key in hotkey recorder | §3.4 |
| **High** | Respect Reduce Motion in all animations | §5.2, §5.3, §5.4 |
| **Medium** | Unify key-code dictionaries | §1.3 |
| **Medium** | Make dependency injection consistent | §2.2 |
| **Medium** | Add dynamic device list refresh | §2.3 |
| **Medium** | Improve language picker UX for 97 items | §4.1 |
| **Medium** | Clarify "Pin Language" label/description | §4.2 |
| **Medium** | Add empty-state messages for pickers | §4.3 |
| **Medium** | Handle unknown key codes gracefully | §6.2 |
| **Low** | Add `Hashable` to `SupportedLanguage` | §2.5 |
| **Low** | Consider flexible window width | §3.2 |
| **Low** | Add "Restore Defaults" button | §3.6 |
| **Low** | Add `accessibilityValue` to pickers | §5.1 |
| **Low** | Add accessibility labels for model status | §5.5 |
| **Low** | Debounce `SettingsStore.save()` | §6.4 |
