# Plan: Build Wispr-like Voice Dictation App in Swift/SwiftUI

## 1. Core Architecture Setup
- Create SwiftUI macOS app with menu bar presence (NSStatusItem)
- Implement app lifecycle with LaunchAtLogin capability
- Set up privacy-first architecture (all processing on-device)
- Configure Info.plist for microphone and accessibility permissions

## 2. Audio Recording System
- Implement AVAudioEngine for microphone capture
- Create audio device selection (list available input devices)
- Build recording state management (idle/recording/processing)
- Add visual feedback UI for recording status
- Implement audio buffer management for Whisper input

## 3. Whisper Model Integration
- Integrate whisper.cpp Swift bindings or CoreML Whisper models
- Build model downloader (fetch Whisper Small/Medium/Large)
- Implement model management (storage, selection, validation)
- Create transcription engine wrapper
- Handle model loading and memory management

## 4. Global Hotkey System
- Use Carbon or Accessibility APIs for global hotkey registration
- Build hotkey recorder UI component
- Implement hotkey conflict detection
- Create customizable hotkey storage (UserDefaults)
- Handle hotkey toggle (start/stop recording)

## 5. Text Insertion via Accessibility
- Request and verify Accessibility permissions
- Implement CGEvent-based text insertion
- Handle text insertion into active application
- Add auto-submit option (simulate Enter key)
- Support special commands (new line, new paragraph)

## 6. Settings & Preferences
- Build SwiftUI settings window with:
  - Hotkey configuration
  - Audio device selector
  - Model selection/download
  - Launch at login toggle
  - Auto-submit toggle
- Persist settings with UserDefaults or AppStorage

## 7. Menu Bar UI
- Create NSStatusItem with icon
- Build menu with:
  - Start/Stop dictation
  - Settings
  - About
  - Quit
- Show recording indicator in menu bar

## 8. Onboarding Flow
- Create first-launch detection
- Build permission request screens (microphone, accessibility)
- Implement model download wizard
- Add quick start tutorial overlay

## 9. Error Handling & Troubleshooting
- Handle permission denials gracefully
- Detect and report model download failures
- Monitor CPU usage and warn if excessive
- Add empty transcription detection
- Implement retry logic for failed operations

## 10. Polish & Distribution
- Add app signing with Developer ID
- Implement notarization for Gatekeeper
- Create DMG installer
- Add app icon and visual assets
- Write README with installation instructions

## Key Technologies:
- SwiftUI for UI
- AVFoundation for audio
- whisper.cpp or CoreML for transcription
- Carbon/Accessibility APIs for global hotkeys
- CGEvent for text insertion
- ServiceManagement for launch at login

## App Features:
- 100% on-device processing (privacy-first)
- Global hotkey activation (default: ⌥ + Space)
- Real-time voice transcription using Whisper
- Text insertion into any application
- Multiple Whisper model support
- Customizable audio input device
- Launch at login option
- Auto-submit capability
- Natural punctuation recognition
