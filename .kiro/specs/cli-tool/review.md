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
  - Checks `~/Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr/` first
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
  - `decode(fileURL:)` — full decode to `[Float]` for short files
  - `decodeChunked(fileURL:chunkDuration:overlapDuration:)` — `AsyncThrowingStream<[Float], Error>` with 30s chunks and 1s overlap
  - `makeReader(for:)` and `extractFloats(from:)` are `private static` — no actor state, pure transformations
  - Throws descriptive `AudioDecoderError` for: file not found, no audio track, unsupported format, decode failure
  - Target membership: both `wispr` and `wispr-cli`
- [ ] 2.2 — Property test: chunked transcription completeness (optional, skipped)
- [ ] 2.3 — Property test: memory boundedness (optional, skipped)
- [ ] 2.4 — Unit tests for AudioFileDecoder (optional, skipped)

### 3. CLI error types and model discovery

- [x] 3.1 — `CLIError` enum (`nonisolated`, `Sendable`, `CustomStringConvertible`) and `DownloadedModelInfo` struct in `wispr-cli/WisprCLI.swift`
- [x] 3.2 — `discoverDownloadedModels()` and `resolveModel(_:)` as instance methods on `WisprCLI`
  - Scans Whisper models under `argmaxinc/whisperkit-coreml/` and Parakeet models
  - Priority: explicit `--model` > UserDefaults `activeModelName` > error
- [ ] 3.3 — Property test: model resolution determinism (optional, skipped)
- [x] 3.4 — `doListModels()` prints model name and size in MB

### 4. Overlap deduplication

- [x] 4.1 — `deduplicateOverlap(previous:current:)` as instance method on `WisprCLI`
  - Compares last N words of previous with first N words of current (N = min(count, 8))
  - Case-insensitive matching, strips matched prefix from current
- [ ] 4.2 — Property test: deduplication correctness (optional, skipped)

### 6. CLI entry point and orchestration

- [x] 6.1 — `wispr-cli/WisprCLI.swift` with `@main struct WisprCLI: AsyncParsableCommand`
  - Arguments: `file` (positional), `--model`, `--language`, `--output`, `--verbose`, `--list-models`, `--version`, `--help`
  - Version from `CFBundleShortVersionString`
  - All helpers are instance methods — no free functions or static helpers
- [x] 6.2 — `transcribe(_:)` orchestration
  - Validates file existence, resolves model, loads via `CompositeTranscriptionEngine`
  - Short files (<=30s): single-shot decode and transcribe
  - Long files (>30s): chunked decode with overlap deduplication
  - Writes to stdout or `--output` file
  - Verbose mode: model load time, audio duration, chunk progress on stderr
- [x] 6.3 — `printStderr(_:)` — all diagnostics to stderr, only transcribed text to stdout
- [ ] 6.4 — Property test: output isolation (optional, skipped)

### 8. CLI installation UI

- [x] 8.1 — `wispr/UI/CLIInstallDialog.swift` with `CLIInstallDialogView`
  - Shows `ln -s` command, "Copy Command" button, "Done" button
- [x] 8.2 — Menu item in `MenuBarController`
  - "Install Command Line Tool..." shown only when `/usr/local/bin/wispr` symlink is missing or points to wrong binary
  - `isCLIInstalled()` check, `showCLIInstallDialog()` presents the dialog
  - Added `@objc` handler in `MenuBarActionHandler`

## Concurrency Design

- No `nonisolated(unsafe)` or `@unchecked Sendable` introduced
- `AudioFileDecoder` is a custom actor; `makeReader` and `extractFloats` are `private static` (no actor state)
- `CLIError`, `TranscribeConfig`, `DownloadedModelInfo`, `AudioMetadata` are all `nonisolated` and `Sendable`
- `decodeChunked` sets up the reader within actor isolation, then returns an `AsyncThrowingStream` whose body uses only static methods

## Files Changed

| File | Change |
|---|---|
| `wispr-cli/WisprCLI.swift` | **New** — CLI entry point, argument parsing, orchestration |
| `wispr/Services/AudioFileDecoder.swift` | **New** — AVAssetReader-based audio decoding |
| `wispr/UI/CLIInstallDialog.swift` | **New** — SwiftUI dialog for CLI install command |
| `wispr/Utilities/ModelPaths.swift` | **Modified** — sandbox-aware path resolution |
| `wispr/UI/MenuBarController.swift` | **Modified** — "Install Command Line Tool..." menu item |
| `wispr.xcodeproj/project.pbxproj` | **Modified** — new target, shared sources, Copy Files phase, ArgumentParser dep |

## Remaining Work (Optional / Phase B)

- Unit tests for `AudioFileDecoder` (format coverage, error cases)
- Property tests for chunked completeness, overlap dedup, model resolution, output isolation
- End-to-end integration test with a known audio file
- Notarization verification of the embedded CLI binary
- Signal handling (SIGINT) for clean cancellation of long transcriptions
- Hybrid CLI mode (connect to running GUI via Unix socket for warm model)
