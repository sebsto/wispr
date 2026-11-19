# Wispr

A macOS menu bar app for local speech-to-text transcription powered by [OpenAI Whisper](https://github.com/openai/whisper), [Qwen3-ASR](https://github.com/QwenLM/Qwen3-ASR) and [NVIDIA Parakeet](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/intro.html).

Wispr runs entirely on-device — your audio never leaves your Mac.

## Features

- **Hotkey-triggered dictation** — press a shortcut to start/stop recording, transcribed text is inserted at the cursor
- **Multi-engine architecture** — choose between OpenAI Whisper, NVIDIA Parakeet and Qwen3-ASR models through a unified interface
- **Multiple models** — Whisper Tiny (~75 MB) to Large v3 (~3 GB) including Large v3 Turbo (~1.6 GB), Parakeet V3 (~400 MB), and Realtime 120M (~150 MB)
- **Low-latency streaming** — Parakeet Realtime 120M provides end-of-utterance detection for near-instant results (English)
- **Model management** — download, activate, switch, and delete models from a single UI
- **Multi-language support** — Whisper supports 90+ languages, Parakeet V3 supports 25 languages and honors `--language` only for non-Latin scripts (Cyrillic, Greek). For Latin-script languages it is only a hint, so use Whisper to fix the language, Qwen3-ASR supports 52 languages and dialects
- **Menu bar native** — lives in your menu bar, stays out of the way
- **Onboarding flow** — guided setup for permissions, model selection, and a test dictation
- **Accessibility-first** — full keyboard navigation, VoiceOver support, and high-contrast mode

## Models

| Model | Engine | Size | Streaming | Languages | Notes |
|-------|--------|------|-----------|-----------|-------|
| Tiny | Whisper | ~75 MB | No | 90+ | Fastest, lower accuracy |
| Base | Whisper | ~140 MB | No | 90+ | Good balance for quick tasks |
| Small | Whisper | ~460 MB | No | 90+ | Solid general-purpose |
| Medium | Whisper | ~1.5 GB | No | 90+ | High accuracy |
| Large v3 Turbo | Whisper | ~1.6 GB | No | 90+ | Near Large v3 accuracy, much faster |
| Large v3 | Whisper | ~3 GB | No | 90+ | Best Whisper accuracy |
| Parakeet V3 | Parakeet | ~400 MB | No | 25 | Fast, high accuracy, multilingual |
| Realtime 120M | Parakeet | ~150 MB | Yes | English | Low-latency with end-of-utterance detection |
| Qwen3-ASR 0.6B | Qwen | ~710 MB | No | 52 | Fast, multilingual |
| Qwen3-ASR 1.7B | Qwen | ~2.5 GB | No | 52 | Higher accuracy, multilingual |

Qwen3-ASR weights are the MLX conversions published by [aufklarer](https://huggingface.co/aufklarer) on Hugging Face.

## Installation

### Homebrew (Recommended)

```bash
brew tap sebsto/macos && brew trust sebsto/macos
brew install wispr
```

### Building from Source

Requires macOS 26.2+ and Xcode 27.2+ (Apple Silicon only)

1. Clone the repo
2. Open `wispr.xcodeproj` in Xcode
3. Build and run (⌘R)
4. Follow the onboarding flow to grant permissions and download a model

## Requirements

- macOS 26.2+
- Apple Silicon (ARM64)
- Microphone permission

## Command-Line Tool

Wispr bundles a CLI for transcribing existing audio and video files offline, at
`Wispr.app/Contents/Resources/bin/WisprCLI`. Symlink it somewhere on your `PATH`:

```bash
ln -s /Applications/Wispr.app/Contents/Resources/bin/WisprCLI /usr/local/bin/wispr-cli
```

```bash
wispr-cli recording.m4a
wispr-cli meeting.mp4 --model large-v3 --language en
wispr-cli lecture.m4a --model turbo   # alias for large-v3-v20240930_turbo
wispr-cli podcast.mp3 --output transcript.txt --verbose
wispr-cli --list-models
```

Supported formats: MP3, WAV, M4A, FLAC, AAC, MP4, MOV. Models are downloaded by the
GUI app, so launch Wispr.app and download at least one model first.

### Full Disk Access is required

The CLI reads models from the GUI app's sandbox container, which macOS protects as
app-private data. Without Full Disk Access it cannot list them and will tell you so.
To grant it:

1. System Settings → Privacy & Security → Full Disk Access
2. Click **+**, then press ⌘⇧G and enter your terminal's path, for example
   `/System/Applications/Utilities/Terminal.app`
3. Enable the toggle, then **quit and reopen** the terminal — the grant only applies
   to newly launched processes

Over SSH the relevant process is `sshd`, so add `/usr/libexec/sshd-keygen-wrapper`
instead. If you use tmux, run `tmux kill-server` and reconnect afterwards, because an
existing tmux server keeps the permissions it was started with.

Note that Full Disk Access applies to every command run in that terminal, not just
`wispr-cli`.

## Architecture

| Layer | Path | Description |
|-------|------|-------------|
| Models | `wispr/Models/` | Data types — model info, permissions, app state, errors |
| Services | `wispr/Services/` | Core logic — audio engine, Whisper/Parakeet integration, hotkey monitoring, settings |
| UI | `wispr/UI/` | SwiftUI views — menu bar, recording overlay, settings, onboarding |
| Utilities | `wispr/Utilities/` | Logging, theming, SF Symbols, preview helpers |

The app uses a `CompositeTranscriptionEngine` that routes to the correct backend (WhisperService, ParakeetService or Qwen3ASRService) based on the selected model. Both engines conform to a shared `TranscriptionEngine` protocol, so switching between them is seamless.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
