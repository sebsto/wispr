# Requirements: Pinned Insertion Target

## User Feedback (translated)

> The ability to set a fixed target window or file for transcription output. I navigate between text files because I take notes across multiple docs or write an email at the same time, but I want the transcription to always go to the same window or file I initially chose.
>
> For this, imagine multi-tasking: I start dictation/transcription in an editor or file, then I go edit another file or email. Having the active window as the default target is a good choice. Then for more flexibility, we could imagine an option with a popup similar to the window picker in Zoom's screen sharing.

## Requirement 1: Capture Insertion Target at Recording Start

**User Story:** As a user, I want dictated text to be inserted into the window I was typing in when I started recording, even if I switch to a different app while the transcription is processing.

**Acceptance Criteria:**
- When the user triggers the hotkey, the app captures a reference to the currently focused text element (PID + AXUIElement) before transitioning to the recording state.
- After transcription completes, text is inserted into the captured element, not the currently focused element.
- If the captured element is no longer valid (app closed, element destroyed), the app falls back to inserting into the currently focused element (existing behavior).
- The clipboard fallback path remains unchanged (inserts into whichever app is frontmost).

## Requirement 2: Pinned Window Mode

**User Story:** As a user, I want to "pin" a specific window so that all my dictations go to that window regardless of what I'm doing, until I unpin it.

**Acceptance Criteria:**
- A menu bar action or settings option allows the user to choose a target window from all open windows.
- While a window is pinned, all transcriptions are inserted into that window's text element, regardless of which app is frontmost.
- The menu bar shows an indicator when a target is pinned (app name / window title).
- The user can unpin via the menu bar.
- If the pinned window is closed, the pin is automatically removed and the user is notified.

## Requirement 3: Window Picker UI

**User Story:** As a user, I want a visual picker (similar to Zoom's screen share dialog) that shows me all open windows so I can choose which one receives my dictations.

**Acceptance Criteria:**
- The picker lists all on-screen windows with their app name and window title.
- The currently active/selected window is visually highlighted.
- Selecting a window pins it as the insertion target.
- The picker can be dismissed without selecting (cancel).
