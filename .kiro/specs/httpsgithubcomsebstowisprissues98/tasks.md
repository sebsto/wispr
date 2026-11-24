# Tasks: SwiftUI review punch list (issue #98)

Delivery: one PR per task, in this order. Each task builds with `swift build` and the CI `xcodebuild` command, and passes `swift test` on the touched suites, before it is pushed. Bug fixes get a test that fails on the old code first.

- [x] 1. Bugs A1 to A3b (requirements A)
  - A1: move hotkey suspend/resume into `HotkeyMonitor` (`beginRecordingSession()` / `endRecordingSession()`); `SettingsView` uses it, and the session ends when the view disappears.
  - A2: set `menu.autoenablesItems = false` in `buildMenu()` in `MenuBarController`.
  - A3: `RecordingOverlayPanel.show()` no longer gates on `isVisible`; `dismiss()` completion only orders out if no show happened since (generation counter).
  - A3b: size the panel from the hosting view's fitting size.
  - Tests: HotkeyMonitor session restores registration when dropped; overlay show-during-dismiss keeps the panel visible (if testable without UI).

- [x] 2. Settings sidebar redesign (requirements H)
  - Render 2 or 3 mockups using the real theme tokens. Wait for the user to pick one.
  - Build the chosen layout: sidebar with the 7 sections and their icons/tints, one section per pane, fixed window size, per-pane scrolling.
  - Keep Restore Defaults and version info reachable as chosen in the mockup.
  - Verify with screenshots; check keyboard and VoiceOver navigation.

- [x] 3. Meeting window and menu performance (requirements B)
  - Extract the level and elapsed-time indicators into small subviews.
  - Build `TranscriptDocument` only in the Export action.
  - Cache `presentSpeakerIndices`; make the speaker palette `private static let`.
  - Split `MenuBarController` observation: a loop for `elapsedTime` that only updates the meeting title; rebuild the language submenu only when the mode changes.

- [x] 4. Structured concurrency (requirements C)
  - `ModelDownloadProgressView`: `.task(id:)` awaits the download directly; add a `Phase` enum; guard progress writes.
  - `RecordingOverlayView`: consume levels in `.task(id: appState)`; add a suspending accessor on `StateManager` for the stream; remove `levelTask` and the polling loop.
  - Test: download is cancelled when the view's task is cancelled (at the model level).

- [x] 5. State management (requirements D)
  - Onboarding test dictation: derive state from `stateManager.appState`; remove the mirrored bindings.
  - Settings model switching: move the activation flow into `StateManager`; bind the picker to one property.
  - Onboarding: hoist download lifecycle state to `OnboardingFlow` so Back/forward cannot start a second download.
  - Test: second start while a download runs is ignored.

- [x] 6. Logic out of views (requirements E)
  - Move transcripts folder and bookmark logic into `TranscriptStore`.
  - Extract an `@Observable` model for model refresh, activation with rollback and deletion with fallback; use it in `ModelManagementView`.
  - Move Parakeet model resolution and "set active model" into `StateManager`.
  - Tests for rollback, fallback selection and bookmark creation.

- [x] 7. Accessibility (requirements F)
  - `ModelRowView`: combine only the info portion, or add `.accessibilityAction(named:)`.
  - Transcript rows: combine into one element.
  - Overlay hint only while `.recording`.
  - Timestamp and speaker columns use `@ScaledMetric(relativeTo: .caption)`.

- [x] 8. Smaller items (requirements G)
  - G1 window release, G2 hotkey recorder focus/Fn monitor/Reduce Motion, G3 F13/F14/Forward Delete key codes, G4 onboarding animations, G5 "Copied!" reset, G6 Close button, G7 rename to `showMeetingWindow()`, G8 onboarding Continue/Skip cleanup and dead code removal, G9 `String` extension and suffix editor, G10 `appVersion` and `checkAvailability()`.
  - Test: the new key codes map to 105, 113 and 117.

- [x] 9. Model Management sidebar (requirements I)
  - Provider sidebar in the same style as the Settings sidebar; detail pane lists the selected provider's models.
  - Open on the provider of the active model and mark it with a checkmark.
  - Keep every provider's list mounted and show only the selected one, so a download keeps running when the user switches provider.
  - Window size 780×560.
