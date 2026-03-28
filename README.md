# Wispr

A macOS menu bar app for local speech-to-text transcription powered by [OpenAI Whisper](https://github.com/openai/whisper) and [NVIDIA Parakeet](https://docs.nvidia.com/nemo-framework/user-guide/latest/nemotoolkit/asr/intro.html).

Wispr runs entirely on-device — your audio never leaves your Mac.

## Features

- **Hotkey-triggered dictation** — press a shortcut to start/stop recording, transcribed text is inserted at the cursor
- **Dual engine architecture** — choose between OpenAI Whisper and NVIDIA Parakeet models through a unified interface
- **Multiple models** — Whisper Tiny (~75 MB) to Large v3 (~3 GB), Parakeet V3 (~400 MB), and Realtime 120M (~150 MB)
- **Low-latency streaming** — Parakeet Realtime 120M provides end-of-utterance detection for near-instant results (English)
- **Model management** — download, activate, switch, and delete models from a single UI
- **Multi-language support** — Whisper supports 90+ languages, Parakeet V3 supports 25 languages
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
| Large v3 | Whisper | ~3 GB | No | 90+ | Best Whisper accuracy |
| Parakeet V3 | Parakeet | ~400 MB | No | 25 | Fast, high accuracy, multilingual |
| Realtime 120M | Parakeet | ~150 MB | Yes | English | Low-latency with end-of-utterance detection |

## Installation

### Homebrew (Recommended)

```bash
brew tap sebsto/macos
brew install wispr
```

### Building from Source

Requires macOS 15.0+ and Xcode 16+

1. Clone the repo
2. Open `wispr.xcodeproj` in Xcode
3. Build and run (⌘R)
4. Follow the onboarding flow to grant permissions and download a model

### Xcode 26.4 build fix

Xcode 26.4 (17E192) introduces stricter Swift 6 concurrency checking that
breaks FluidAudio 0.12.4 with `sending 'asrManager' risks causing data races`
errors. Xcode 26.3 builds fine without changes. WhisperKit 0.17.0 pins
`swift-transformers` to `< 1.2.0`, which caps FluidAudio at 0.12.4 and
prevents upgrading to a fixed version.

**Workaround:** after Xcode resolves packages, run the following from the
project root to patch the FluidAudio checkout:

```bash
# Path to the FluidAudio checkout inside DerivedData
FLUID_ASR="$(xcodebuild -showBuildSettings 2>/dev/null | grep -m1 BUILD_DIR | awk '{print $3}' | sed 's|/Build/Products||')/SourcePackages/checkouts/FluidAudio/Sources/FluidAudio/ASR/AsrManager.swift"

# Make writable and apply the patch
chmod u+w "$FLUID_ASR"
sed -i '' 's/^public final class AsrManager {/public final class AsrManager: @unchecked Sendable {/' "$FLUID_ASR"
```

This adds `@unchecked Sendable` conformance to `AsrManager`, which is safe
because it is only accessed from within `StreamingAsrManager`'s actor isolation
domain. The patch must be reapplied whenever Xcode re-resolves packages (e.g.
after a clean or `Package.resolved` change).

The fix will no longer be needed once the upstream issues are resolved:
[argmaxinc/WhisperKit#451](https://github.com/argmaxinc/WhisperKit/issues/451),
[FluidInference/FluidAudio#448](https://github.com/FluidInference/FluidAudio/issues/448).

## Requirements

- macOS 15.0+
- Microphone permission

## Architecture

| Layer | Path | Description |
|-------|------|-------------|
| Models | `wispr/Models/` | Data types — model info, permissions, app state, errors |
| Services | `wispr/Services/` | Core logic — audio engine, Whisper/Parakeet integration, hotkey monitoring, settings |
| UI | `wispr/UI/` | SwiftUI views — menu bar, recording overlay, settings, onboarding |
| Utilities | `wispr/Utilities/` | Logging, theming, SF Symbols, preview helpers |

The app uses a `CompositeTranscriptionEngine` that routes to the correct backend (WhisperService or ParakeetService) based on the selected model. Both engines conform to a shared `TranscriptionEngine` protocol, so switching between them is seamless.

## License

This project is licensed under the Apache License 2.0. See [LICENSE](LICENSE) for details.
