# Meeting Transcription Mode — Implementation Plan

## Overview
Add a new "Meeting Mode" to Wispr that:
1. Shows a floating square window with recording controls and live transcript
2. Captures both system audio (what others say in meetings) and microphone audio (what you say)
3. Separates speakers into "You" vs "Others" based on audio source
4. Displays a scrolling live transcript in the window
5. Allows copying/exporting the transcript for notes

## Architecture Decisions

### System Audio Capture
macOS requires `ScreenCaptureKit` (macOS 13+) to capture system audio. This is the only sanctioned API — `AVAudioEngine` can only capture microphone input. We'll use `SCStreamConfiguration` with `capturesAudio = true` and `excludesCurrentProcessAudio = true`.

This requires the **Screen Recording** permission (user grants in System Settings > Privacy & Security > Screen Recording).

### Speaker Separation Strategy
Instead of ML-based diarization (complex, heavy), we use a simple but effective approach:
- **Microphone audio** → labeled as "You"
- **System audio** → labeled as "Others"

This works perfectly for meetings because system audio = remote participants, mic = you.

### Dual Audio Engine
Create a new `MeetingAudioEngine` actor that runs two capture pipelines in parallel:
1. `AVAudioEngine` for microphone (existing approach)
2. `SCStreamConfiguration` for system audio

Both streams are resampled to 16kHz mono Float32 and fed to separate transcription instances.

### Transcription Approach
Run two parallel transcription sessions:
- One for mic audio chunks → "You:" prefix
- One for system audio chunks → "Others:" prefix

Use chunked transcription (process every ~5-10 seconds of audio) for near-real-time results.

## Implementation Tasks

### Phase 1: Core Infrastructure
- [x] 1.1 Create `MeetingTranscript` model (timestamped entries with speaker labels)
- [x] 1.2 Create `MeetingAudioEngine` actor (dual capture: mic + system audio via ScreenCaptureKit)
- [x] 1.3 Create `MeetingStateManager` (orchestrates meeting mode state machine)
- [x] 1.4 Add Screen Recording permission handling to `PermissionManager`

### Phase 2: Meeting Mode UI
- [x] 2.1 Create `MeetingTranscriptView` (scrolling transcript with speaker labels)
- [x] 2.2 Create `MeetingWindowPanel` (floating square NSPanel with controls)
- [x] 2.3 Add "Meeting Mode" menu item to `MenuBarController`
- [x] 2.4 Wire meeting window visibility to `MeetingStateManager`

### Phase 3: Integration
- [x] 3.1 Add meeting mode settings to `SettingsStore` (not needed for MVP — uses existing language settings)
- [x] 3.2 Wire up `WisprAppDelegate` to bootstrap meeting mode services
- [x] 3.3 Add transcript export (copy to clipboard / save as text file)

## File Plan
```
wispr/Models/MeetingTranscript.swift          — transcript data model
wispr/Services/MeetingAudioEngine.swift       — dual audio capture
wispr/Services/MeetingStateManager.swift      — meeting mode coordinator
wispr/UI/Meeting/MeetingTranscriptView.swift  — transcript UI
wispr/UI/Meeting/MeetingWindowPanel.swift     — floating window
```
