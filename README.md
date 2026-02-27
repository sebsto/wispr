# Wispr

A macOS menu bar app for local speech-to-text transcription powered by [OpenAI Whisper](https://github.com/openai/whisper).

Wispr runs entirely on-device — your audio never leaves your Mac.

## Features

- **Hotkey-triggered dictation** — press a shortcut to start/stop recording, transcribed text is inserted at the cursor
- **Multiple Whisper models** — choose from Tiny (~75 MB) to Large v3 (~3 GB) depending on your speed/accuracy needs
- **Model management** — download, activate, and delete models from a single UI
- **Multi-language support** — transcribe in any language Whisper supports
- **Menu bar native** — lives in your menu bar, stays out of the way
- **Onboarding flow** — guided setup for permissions, model selection, and a test dictation
- **Accessibility-first** — full keyboard navigation, VoiceOver support, and high-contrast mode

## Requirements

- macOS 15.0+
- Xcode 16+
- Microphone permission
- Accessibility permission (for text insertion)

## Getting Started

1. Clone the repo
2. Open `wispr.xcodeproj` in Xcode
3. Build and run (⌘R)
4. Follow the onboarding flow to grant permissions and download a model

## Architecture

| Layer | Path | Description |
|-------|------|-------------|
| Models | `wispr/Models/` | Data types — model info, permissions, app state, errors |
| Services | `wispr/Services/` | Core logic — audio engine, Whisper integration, hotkey monitoring, settings |
| UI | `wispr/UI/` | SwiftUI views — menu bar, recording overlay, settings, onboarding |
| Utilities | `wispr/Utilities/` | Logging, theming, SF Symbols, preview helpers |

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
