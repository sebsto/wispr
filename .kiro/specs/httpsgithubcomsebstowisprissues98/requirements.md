# SwiftUI review punch list (sebsto/wispr issue #98)

## Goal

Fix the bugs, performance problems, structured-concurrency violations, state anti-patterns and accessibility gaps found in the review of `Sources/WisprApp/UI/`. Behavior the user sees stays the same, except where a bug is fixed. Items from the "What's already good" list must not regress.

## Acceptance

### A. Bugs
- A1. Closing Settings while a hotkey is being recorded re-registers the global hotkey. Registration is restored even if the view is destroyed.
- A2. The Start/Stop Recording menu item is really disabled while the app state is `.processing`.
- A3. Re-triggering recording during the overlay fade-out always shows the overlay. A pending dismiss never hides a newer show.
- A3b. The overlay panel grows with large accessibility text sizes and does not clip content.

### B. Performance
- B1. Audio level and elapsed time updates re-render only their own small subviews in the meeting window, not the whole window.
- B2. The `TranscriptDocument` is built only when the user exports, not on every body pass.
- B3. `presentSpeakerIndices` is cached, and the speaker color palette is a `static let`.
- B4. During a meeting, the 1 Hz elapsed-time tick updates only the meeting menu item title. The language submenu is rebuilt only when the language mode changes.

### C. Structured concurrency
- C1. Model download runs inside `.task`, with no `Task` stored in `@State`. Leaving the view cancels the download.
- C2. Download UI state is one `Phase` enum with an exhaustive `switch`. Progress writes happen only when the value changed.
- C3. The overlay level stream is consumed in the existing `.task(id: appState)`. No sleep-polling loop and no stored `levelTask`.

### D. State management
- D1. Onboarding test-dictation derives recording/processing from `stateManager.appState`. The mirrored bindings are removed.
- D2. Model switching in Settings is owned by `StateManager`. The picker binds to one property.
- D3. Going Back and forward in onboarding never starts a second download while one is running.

### E. Logic out of views
- E1. Transcript folder and bookmark logic lives in `TranscriptStore` (or a small model). The view only presents the panel.
- E2. Model refresh, activation with rollback and deletion with fallback live in an `@Observable` model, not `ModelManagementView`.
- E3. Parakeet model resolution and "set active model" live in `StateManager`, once.

### F. Accessibility
- F1. Model rows keep their Download/Activate/Delete buttons reachable in VoiceOver.
- F2. Transcript rows read as one VoiceOver element.
- F3. The "Release the hotkey to stop recording" hint is announced only while `.recording`.
- F4. Timestamp and speaker columns scale with text size (`@ScaledMetric`).

### G. Smaller items
- G1. Settings and model-management windows set `isReleasedWhenClosed = false` and release their reference on close.
- G2. Mouse-only users can record a hotkey. The Fn monitor is reinstalled on appear when still recording. The animation respects Reduce Motion.
- G3. F13, F14 (and Forward Delete) can be recorded as hotkeys.
- G4. Onboarding permission status changes animate, and respect Reduce Motion.
- G5. "Copied!" resets after about 2 seconds.
- G6. The model-management Close button closes its own window, not the key window.
- G7. `toggleMeetingMode()` is renamed `showMeetingWindow()`.
- G8. Unused `placeholderStepContent` is deleted. The onboarding Continue button renders once, with Skip shown beside it when allowed, and the dead `.disabled` is removed.
- G9. `visibleWhitespace` becomes a `String` extension. The suffix editor seeds its draft in `init` and dismisses with `@Environment(\.dismiss)`.
- G10. `appVersion` is a `static let`. `checkAvailability()` runs from the top-level `.task`.
- G11. `listItems` is left as is (the issue says it is fine at current size).

### H. Settings window redesign
- H1. The Settings window has a sidebar on the left listing every section: Shortcut, Audio Device, Recognition, After Transcription, Feedback, Meeting, General. The right side shows only the selected section. No long scroll list.
- H2. Each sidebar row keeps the icon and tint it has today in its `SectionHeader`.
- H3. The window opens on the first section. It can be navigated with the keyboard and VoiceOver, and each row has an accessibility label.
- H4. The window has a fixed, sensible size and no longer needs the 600 pt height cap. A section that is taller than the window scrolls inside its own pane.
- H5. All current settings, bindings and behavior stay the same. Only the layout changes.
- H6. Before code, 2 or 3 mockups are shown and the user picks one. The chosen mockup is the visual spec.
- H7. Restore Defaults and the version info stay reachable (placement is decided in the mockup step).

### Done when
- The project builds with the CI `xcodebuild` command and `swift build`, and existing tests pass.
- Each bug fix (A1 to A3, C1, D3, G3) has a test that fails on the old code, where the logic is testable without UI.
