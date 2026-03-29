# Implementation Plan: CLI Transcription Tool (wispr-cli)

## Overview

Incrementally build the `wispr-cli` command-line tool embedded in the Wispr app bundle. Each task builds on the previous, starting with project setup and shared types, then core decoding and transcription logic, then CLI argument parsing and orchestration, and finally GUI integration for CLI installation. All code is Swift 6 with strict concurrency.

## Tasks

- [ ] 1. Set up the wispr-cli Xcode target and project structure
  - [ ] 1.1 Create the `wispr-cli` command-line tool target in the Xcode project
    - Add a new target of type `com.apple.product-type.tool` named `wispr-cli`
    - Set Bundle Identifier to `com.stormacq.mac.wispr-cli`, Swift Language Version 6, Strict Concurrency `complete`
    - Enable Hardened Runtime (`ENABLE_HARDENED_RUNTIME = YES`), disable App Sandbox (`ENABLE_APP_SANDBOX = NO`)
    - Set `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` and `SWIFT_STRICT_CONCURRENCY = complete` to match the GUI app target (required for shared source files to compile with identical isolation semantics)
    - Set deployment target to macOS 26.2
    - Add `swift-argument-parser` as a Swift Package dependency and link `ArgumentParser` to the `wispr-cli` target only
    - Link WhisperKit and FluidAudio frameworks to the `wispr-cli` target
    - _Requirements: 1.1, 1.2, 1.3, 1.4, 1.6, 1.7_
  - [ ] 1.2 Update `ModelPaths.base` for sandbox-aware path resolution
    - Modify `wispr/Utilities/ModelPaths.swift` so that `base` checks for the GUI app's sandbox container at `~/Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr/` and uses it when it exists
    - When the container path does not exist (e.g. inside the sandbox itself, or first launch), fall back to the standard `FileManager.urls(for: .applicationSupportDirectory)` path
    - This ensures the non-sandboxed CLI reads models from the same location the sandboxed GUI app writes them
    - Verify the GUI app still resolves its own sandboxed path correctly (inside the sandbox, `FileManager` already redirects to the container, so the container check is a no-op)
    - _Requirements: 3.1, 8.1_
  - [ ] 1.3 Configure shared source file target membership
    - Add target membership for `wispr-cli` to: `WhisperService.swift`, `ParakeetService.swift`, `CompositeTranscriptionEngine.swift`, `TranscriptionEngine.swift`, `ModelInfo.swift`, `TranscriptionResult.swift`, `TranscriptionLanguage.swift`, `ModelStatus.swift`, `WisprError.swift`, `DownloadProgress.swift`, `ModelPaths.swift`, `Logger.swift`
    - Verify these files compile under both the `wispr` and `wispr-cli` targets without errors
    - _Requirements: 8.1, 8.3, 8.4, 8.5_
  - [ ] 1.4 Add a Copy Files build phase to embed wispr-cli in the app bundle
    - In the `wispr` (GUI app) target, add a Copy Files phase: Destination "Resources", Subpath `bin`, add the `wispr-cli` product, check "Code Sign On Copy"
    - _Requirements: 1.2, 1.3, 1.5_

- [ ] 1b. Checkpoint — Verify ModelPaths sandbox resolution
  - Build both the `wispr` and `wispr-cli` targets, confirm no compile errors
  - Manually verify that `ModelPaths.base` resolves to the sandbox container path when run from the CLI (non-sandboxed context)

- [ ] 2. Implement AudioFileDecoder
  - [ ] 2.1 Create `wispr/Services/AudioFileDecoder.swift` with the `AudioFileDecoder` actor
    - Implement `AudioMetadata` as `nonisolated struct AudioMetadata: Sendable` with `duration`, `sampleRate`, `channelCount`, `estimatedSampleCount`. Must be `nonisolated` and `Sendable` to cross from the actor's isolation back to `@MainActor` callers.
    - Implement `metadata(for:)` using `AVAsset` to read audio track info without decoding
    - Implement `decode(fileURL:)` using `AVAssetReader` + `AVAssetReaderTrackOutput` configured for 16 kHz mono Float32 PCM output. This is the primary decoding path — the full audio is decoded and passed to the transcription engine, which handles its own chunking internally.
    - Optionally implement `decodeChunked(fileURL:chunkDuration:overlapDuration:)` returning `AsyncThrowingStream<[Float], Error>` for potential future use, but the CLI SHALL NOT use it for transcription (engines handle chunking natively).
    - Throw descriptive errors for: file not found, no audio track, unsupported format, read failure
    - Add target membership for both `wispr` and `wispr-cli` targets
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 2.7, 8.1_

  - [ ]* 2.2 Write unit tests for AudioFileDecoder
    - Test decoding of each supported format (MP3, WAV, M4A, FLAC, AAC, MP4, MOV) using short bundled test fixtures
    - Verify output is 16 kHz mono Float32
    - Test error cases: missing file, no audio track, unsupported format
    - _Requirements: 2.1, 2.2, 2.3, 2.5, 2.6, 2.7_

- [ ] 3. Implement CLI error types and model discovery
  - [ ] 3.1 Create `CLIError` enum and `DownloadedModelInfo` in `wispr-cli/WisprCLI.swift`
    - Implement `CLIError` as `nonisolated enum CLIError: Error, CustomStringConvertible, Sendable` with cases: `noModelsDirectory`, `noDownloadedModels`, `noActiveModel`, `modelNotFound`, `fileNotFound`. Must be `nonisolated` because with `@MainActor` default isolation it would otherwise be `@MainActor`, preventing construction inside custom actors.
    - Audio decoding errors are thrown by `AudioFileDecoder` as `AudioDecoderError` — no wrapping in `CLIError` needed.
    - Implement `DownloadedModelInfo` as `nonisolated struct DownloadedModelInfo: Sendable` with `name`, `sizeOnDisk`, `path`. Must be `nonisolated` for the same reason — used across isolation boundaries.
    - _Requirements: 1.7, 3.4, 3.5, 4.8_
  - [ ] 3.2 Implement `discoverDownloadedModels()` and `resolveModel(_:)` as instance methods on `WisprCLI`
    - `discoverDownloadedModels()` scans `ModelPaths.models` (sandbox-aware, resolves to the GUI app's container) for valid model subdirectories
    - `resolveModel(_:)` follows priority: explicit `--model` flag > `UserDefaults(suiteName: "com.stormacq.mac.wispr").string(forKey: "activeModelName")` > error
    - Throw `CLIError.modelNotFound` with available model names when specified model is missing
    - Throw `CLIError.noActiveModel` when no default can be determined
    - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5_

  - [ ]* 3.3 Write property test: Model resolution determinism (Property 2)
    - **Property 2: Model resolution determinism**
    - For any combination of explicit model name, UserDefaults active model, and set of downloaded models, verify `resolveModel()` returns the same result given the same inputs
    - Verify priority order: explicit flag > UserDefaults > error
    - **Validates: Requirements 3.2, 3.3, 3.4**

  - [ ] 3.4 Implement `doListModels()` as an instance method on `WisprCLI`
    - Print each downloaded model's name and size to stdout
    - Exit with code 0 after listing
    - _Requirements: 3.6_

- [ ] 4. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 5. Implement CLI entry point and transcription orchestration
  - [ ] 5.1 Create `wispr-cli/WisprCLI.swift` with `WisprCLI` struct using `swift-argument-parser`
    - Implement `@main struct WisprCLI: AsyncParsableCommand` with all arguments and flags: `file` (argument), `--model`, `--language`, `--output`, `--verbose`, `--list-models`, `--version`, `--help`. Note: `@MainActor` is implicit from `SWIFT_DEFAULT_ACTOR_ISOLATION` — do not add it explicitly.
    - `static let configuration` is required by `AsyncParsableCommand` protocol — this is the only acceptable static property. Use `Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")` for the version string (no separate `AppVersion` type).
    - All helper functions (`transcribe`, `resolveModel`, `discoverDownloadedModels`, `doListModels`, `printStderr`, `writeOutput`) are instance methods on `WisprCLI` — no free functions or static helpers.
    - Validate that when invoked with no arguments, usage info is printed to stderr and exits non-zero
    - _Requirements: 4.3, 4.7, 5.1, 5.2, 5.3, 5.4_
  - [ ] 5.2 Implement the `transcribe(_:)` orchestration as an instance method on `WisprCLI`
    - Validate file existence, resolve model, load model via `CompositeTranscriptionEngine`, decode full audio via `AudioFileDecoder.decode(fileURL:)`
    - Pass the full decoded audio to the engine in a single `engine.transcribe(samples, language:)` call — the engine handles its own chunking internally
    - Write transcribed text to stdout (default) or to `--output` file
    - Print progress/timing to stderr when `--verbose` is set (model load time, audio duration, sample count)
    - Print only transcribed text to stdout with no headers or metadata
    - _Requirements: 4.1, 4.2, 4.4, 4.5, 4.6, 4.7, 4.8, 4.9, 7.1, 7.2_
  - [ ] 5.3 Implement `printStderr(_:)` as an instance method on `WisprCLI` and wire all error/diagnostic output to stderr
    - All `CLIError` messages, verbose output, and progress messages go to stderr
    - Only transcribed text goes to stdout
    - _Requirements: 4.5, 4.6_

  - [ ]* 5.4 Write property test: Output isolation (Property 1)
    - **Property 1: Output isolation**
    - For any invocation of the transcription flow, verify all diagnostic and progress messages are written to stderr and only transcribed text is written to stdout
    - **Validates: Requirements 4.4, 4.5**

- [ ] 6. Checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 7. Implement CLI installation UI in the GUI app
  - [ ] 7.1 Create `wispr/UI/CLIInstallDialog.swift` with `CLIInstallDialogView`
    - SwiftUI view showing the `ln -sf` command to create the symlink from `/usr/local/bin/wispr` to the app bundle's `wispr-cli`
    - Uses `-sf` to handle existing symlinks pointing to wrong targets
    - Include a "Copy Command" button that copies the command to the clipboard via `NSPasteboard`
    - Include a "Done" button to dismiss
    - _Requirements: 6.2, 6.3, 6.4, 6.5_
  - [ ] 7.2 Add "Install Command Line Tool..." menu item to `MenuBarController`
    - Add `isCLIInstalled()` check: verify `/usr/local/bin/wispr` exists and points to the correct binary in the current app bundle
    - Show the menu item only when the CLI is not installed (symlink missing or pointing to wrong location)
    - Use `SFSymbols.terminal` constant for the menu item icon
    - Wire the menu item action to present `CLIInstallDialogView`
    - _Requirements: 6.1, 6.2, 6.5_

- [ ] 8. Final checkpoint - Ensure all tests pass
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- **Concurrency**: The project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. All top-level types/functions are implicitly `@MainActor`. Pure data types that cross isolation boundaries (errors, configs, metadata) MUST be `nonisolated` and `Sendable`. Do NOT add explicit `@MainActor` annotations — they are redundant and add noise.
- **`nonisolated(unsafe)`**: The spec introduces NO new `nonisolated(unsafe)` usage. Existing usages in shared files (`WhisperService.whisperKit`, `ParakeetService.asrManager/eouManager`) are justified by actor isolation guaranteeing serial access to non-Sendable third-party types.
- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation
- Property tests validate universal correctness properties from the design document
- The design uses Swift throughout — all implementation tasks use Swift 6 with strict concurrency
- Shared code is handled via Xcode target membership, not a separate framework
