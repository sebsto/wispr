# Implementation Review: CLI Transcription Tool (wispr-cli)

## Status: Phase A — Core implementation complete

Both `wispr` and `wispr-cli` targets build successfully (Debug). All existing tests pass (`TEST SUCCEEDED`).

## Completed Tasks

### 1. Xcode project setup

- [x] 1.1 — Created `wispr-cli` command-line tool target (`com.apple.product-type.tool`)
  - Bundle ID: `com.stormacq.mac.wispr-cli`
  - Swift 6, strict concurrency `complete`, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
  - `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO`
  - Deployment target: macOS 26.2
  - Added `swift-argument-parser` (1.5.0+) as SPM dependency, linked to `wispr-cli` only
  - Linked WhisperKit and FluidAudio frameworks
- [x] 1.2 — Updated `ModelPaths.base` for sandbox-aware resolution
  - Detects sandbox via `APP_SANDBOX_CONTAINER_ID` environment variable
  - Non-sandboxed CLI checks `~/Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr/` first
  - Falls back to standard Application Support when container doesn't exist
  - GUI app unaffected (inside sandbox, FileManager already redirects)
- [x] 1.3 — Configured shared source file target membership
  - Used `PBXFileSystemSynchronizedBuildFileExceptionSet` to include 13 files from `wispr/` in the `wispr-cli` target:
    - Models: `DownloadProgress`, `ModelInfo`, `ModelStatus`, `TranscriptionLanguage`, `TranscriptionResult`, `WisprError`
    - Services: `AudioFileDecoder`, `CompositeTranscriptionEngine`, `ParakeetService`, `TranscriptionEngine`, `WhisperService`
    - Utilities: `Logger`, `ModelPaths`
- [x] 1.4 — Added Copy Files build phase to embed `wispr-cli` in app bundle
  - Destination: Resources, subpath `bin`, Code Sign On Copy enabled
  - `wispr` target depends on `wispr-cli` target (auto-builds)

### 2. AudioFileDecoder

- [x] 2.1 — Created `wispr/Services/AudioFileDecoder.swift`
  - `actor AudioFileDecoder` with `nonisolated struct AudioMetadata: Sendable`
  - `metadata(for:)` — reads audio track info without decoding
  - `decode(fileURL:)` — full decode to `[Float]` (primary path for all files)
  - `decodeChunked(fileURL:chunkDuration:overlapDuration:)` — retained for potential future use, but NOT used by CLI (engines handle chunking natively)
  - Preconditions on `chunkDuration`/`overlapDuration` for safety
  - Early return guard for zero-length buffers in `extractFloats`
  - `makeReader(for:)` and `extractFloats(from:)` are `private static` — no actor state, pure transformations
  - Throws descriptive `AudioDecoderError` for: file not found, no audio track, unsupported format, decode failure
  - Target membership: both `wispr` and `wispr-cli`
- [ ] 2.2 — Unit tests for AudioFileDecoder (Phase B)

### 3. CLI error types and model discovery

- [x] 3.1 — `CLIError` enum (`nonisolated`, `Sendable`, `CustomStringConvertible`) and `DownloadedModelInfo` struct in `wispr-cli/WisprCLI.swift`
  - Cases: `noModelsDirectory`, `noDownloadedModels`, `noActiveModel`, `modelNotFound`, `fileNotFound`
  - Audio decoding errors handled by `AudioDecoderError`, transcription errors by `WisprError` — no wrapping needed
- [x] 3.2 — `discoverDownloadedModels()` and `resolveModel(_:)` as instance methods on `WisprCLI`
  - Scans Whisper models under `argmaxinc/whisperkit-coreml/` and Parakeet models
  - Priority: explicit `--model` > GUI app's UserDefaults (`suiteName: "com.stormacq.mac.wispr"`) > error
- [x] 3.4 — `doListModels()` prints model name and size in MB

### 5. CLI entry point and orchestration

- [x] 5.1 — `wispr-cli/WisprCLI.swift` with `@main struct WisprCLI: AsyncParsableCommand`
  - Arguments: `file` (positional), `--model`, `--language`, `--output`, `--verbose`, `--list-models`, `--version`, `--help`
  - Version from `CFBundleShortVersionString`
  - All helpers are instance methods — no free functions or static helpers
- [x] 5.2 — `transcribe(_:)` orchestration
  - Validates file existence, resolves model, loads via `CompositeTranscriptionEngine`
  - Decodes full audio via `AudioFileDecoder.decode(fileURL:)` regardless of duration
  - Passes full decoded samples to `engine.transcribe(samples, language:)` in a single call
  - Engine handles its own chunking internally (Parakeet `ChunkProcessor` / WhisperKit `chunkingStrategy`)
  - Writes to stdout or `--output` file
  - Verbose mode: model load time, audio duration, sample count on stderr
- [x] 5.3 — `printStderr(_:)` — all diagnostics to stderr, only transcribed text to stdout

### 7. CLI installation UI

- [x] 7.1 — `wispr/UI/CLIInstallDialog.swift` with `CLIInstallDialogView`
  - Shows `ln -sf` command (handles existing symlinks), "Copy Command" button, "Done" button
- [x] 7.2 — Menu item in `MenuBarController`
  - "Install Command Line Tool..." shown only when `/usr/local/bin/wispr` symlink is missing or points to wrong binary
  - Uses `SFSymbols.terminal` constant for icon
  - `isCLIInstalled()` check, `showCLIInstallDialog()` presents the dialog
  - Added `@objc` handler in `MenuBarActionHandler`

## Design Decisions

### Why no CLI-side chunking

Early implementation split long files into 30s chunks with 1s overlap and word-level deduplication. This was removed because:

1. **Double chunking**: The CLI's 30s chunks were re-chunked by Parakeet's `ChunkProcessor` (~15s with frame-aligned boundaries, 2s overlap, mel context prepending), destroying the engine's context windows
2. **Lost context**: Each 30s chunk started "cold" — the engine's decoder had no token history from previous chunks
3. **Naive deduplication**: Word-level overlap matching garbled text at boundaries, especially for non-English content
4. **Quality impact**: French podcast transcription showed severe degradation ("Bastien Storm-Ake" vs "Sébastien Stormach") compared to the same audio transcribed by the engine with native chunking

The fix: pass the full decoded audio to the engine and let it handle segmentation. Memory impact is minimal (~19MB for a 20-minute podcast at 16kHz mono Float32).

## Concurrency Design

- No `nonisolated(unsafe)` or `@unchecked Sendable` introduced
- `AudioFileDecoder` is a custom actor; `makeReader` and `extractFloats` are `private static` (no actor state)
- `CLIError`, `TranscribeConfig`, `DownloadedModelInfo`, `AudioMetadata` are all `nonisolated` and `Sendable`

## Files Changed

| File | Change |
|---|---|
| `wispr-cli/WisprCLI.swift` | **New** — CLI entry point, argument parsing, orchestration |
| `wispr/Services/AudioFileDecoder.swift` | **New** — AVAssetReader-based audio decoding |
| `wispr/UI/CLIInstallDialog.swift` | **New** — SwiftUI dialog for CLI install command |
| `wispr/Utilities/ModelPaths.swift` | **Modified** — sandbox-aware path resolution |
| `wispr/Utilities/SFSymbols.swift` | **Modified** — added `terminal` constant |
| `wispr/UI/MenuBarController.swift` | **Modified** — "Install Command Line Tool..." menu item |
| `wispr.xcodeproj/project.pbxproj` | **Modified** — new target, shared sources, Copy Files phase, ArgumentParser dep |

## Remaining Work (Phase B)

- Unit tests for `AudioFileDecoder` (format coverage, error cases)
- End-to-end integration test with a known audio file
- Notarization verification of the embedded CLI binary
- Signal handling (SIGINT) for clean cancellation of long transcriptions
- Hybrid CLI mode (connect to running GUI via Unix socket for warm model)
