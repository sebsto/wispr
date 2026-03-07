---
inclusion: auto
description: Automatically loads Wispr project context at the start of each session
---

# Wispr Project Context

This steering file automatically loads at the start of each session to provide project context.

## Project Overview

Wispr is a macOS menu bar app for local speech-to-text transcription powered by OpenAI Whisper. All processing happens on-device.

## Key Architecture

- **Models** (`wispr/Models/`) - Data types for model info, permissions, app state, errors
- **Services** (`wispr/Services/`) - Core logic including:
  - `AudioEngine.swift` - Audio capture
  - `WhisperService.swift` - Whisper model integration
  - `ParakeetService.swift` - Alternative transcription engine
  - `CompositeTranscriptionEngine.swift` - Combines multiple engines
  - `HotkeyMonitor.swift` - Keyboard shortcut handling
  - `StateManager.swift` - App state coordination
  - `SettingsStore.swift` - User preferences
- **UI** (`wispr/UI/`) - SwiftUI views for menu bar, recording overlay, settings, onboarding
- **Utilities** (`wispr/Utilities/`) - Logging, theming, helpers

## Tech Stack

- Swift 6 with strict concurrency
- SwiftUI for UI
- macOS 26.0+ target
- Xcode 26+

## Important Files to Review

When starting a session, consider reviewing:

1. **Recent changes**: #[[file:../.git/logs/HEAD]] or run `git log -5 --oneline`
2. **Project structure**: The README at #[[file:../README.md]]
3. **Build configuration**: #[[file:../wispr.xcodeproj/project.pbxproj]]
4. **Entitlements**: #[[file:../wispr.entitlements]]

## Development Workflow

- Build with Xcode or `make archive`
- Tests in `wisprTests/` directory
- CI/CD via GitHub Actions (`.github/workflows/`)
- Distribution via Homebrew and direct download

## Common Tasks

- **Adding features**: Start in Services layer, expose via StateManager, connect to UI
- **Fixing bugs**: Check logs, review StateManager state transitions, verify permissions
- **Testing**: Unit tests in wisprTests/, focus on Services layer
- **UI changes**: SwiftUI views in UI/, use PreviewHelpers for development

## Session Initialization

At the start of each session, you should:
1. Check the latest git commit for recent changes
2. Review any open issues or TODOs in .kiro/
3. Understand the current state of the codebase
