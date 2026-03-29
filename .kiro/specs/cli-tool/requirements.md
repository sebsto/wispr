# Requirements Document

## Introduction

This feature adds a command-line tool (`wispr-cli`) to the Wispr application bundle. The CLI tool transcribes pre-recorded audio and video files using the same on-device transcription engines (WhisperKit, FluidAudio) and downloaded models already managed by the GUI app. Users can optionally install the CLI to a directory in their PATH (e.g., `/usr/local/bin/`) for convenient terminal access, similar to how Xcode provides `xcodebuild` or VS Code provides the `code` command.

The CLI binary is embedded inside `Wispr.app/Contents/Resources/bin/` and is signed with Hardened Runtime but **without** App Sandbox entitlements, allowing it to read arbitrary file paths passed as arguments. The GUI app remains sandboxed. Both the CLI and GUI share the same model files on disk at `~/Library/Application Support/wispr/models/`.

## Glossary

- **wispr-cli**: The command-line executable embedded in the Wispr application bundle for file-based transcription.
- **CLI_Target**: The Xcode build target that produces the `wispr-cli` binary.
- **GUI_App**: The existing sandboxed Wispr menu bar application.
- **Shared_Models_Directory**: The directory where both the GUI_App and wispr-cli read transcription models. Because the GUI_App is sandboxed, models are stored at `~/Library/Containers/com.stormacq.mac.wispr/Data/Library/Application Support/wispr/models/`. The non-sandboxed CLI resolves this path directly.
- **AudioFileDecoder**: The component responsible for decoding audio/video files into raw PCM float samples suitable for the transcription engines.
- **TranscriptionEngine**: The existing protocol abstracting speech-to-text backends (WhisperKit, FluidAudio).
- **Install_CLI_Action**: The GUI_App menu item or onboarding step that helps the user create a symlink to wispr-cli in their PATH.

## Requirements

### Requirement 1: CLI Binary Embedded in App Bundle

**User Story:** As a user, I want the CLI tool to ship inside the Wispr app bundle so that I get it automatically when I install or update Wispr.

#### Acceptance Criteria

1. THE CLI_Target SHALL produce an executable binary named `wispr-cli`.
2. THE build process SHALL embed `wispr-cli` at `Wispr.app/Contents/Resources/bin/wispr-cli`.
3. THE `wispr-cli` binary SHALL be signed with Hardened Runtime enabled.
4. THE `wispr-cli` binary SHALL NOT have App Sandbox entitlements.
5. THE `wispr-cli` binary SHALL be included in the notarization of the Wispr application bundle.
6. THE CLI_Target SHALL compile under Swift 6 with strict concurrency checking enabled (`complete`), default actor isolation set to `MainActor` (matching the GUI_App target), and no warnings.
7. ALL data types used across isolation boundaries (error enums, config structs, metadata structs) SHALL be explicitly marked `nonisolated` and conform to `Sendable` so they can cross between `@MainActor` and custom actor isolation domains without compiler errors.

### Requirement 2: Audio and Video File Decoding

**User Story:** As a user, I want to pass audio or video files to the CLI so that I can transcribe pre-recorded content.

#### Acceptance Criteria

1. THE AudioFileDecoder SHALL accept file paths to audio files in the following formats: MP3, WAV, M4A, FLAC, AAC.
2. THE AudioFileDecoder SHALL accept file paths to video files in the following formats: MP4, MOV.
3. THE AudioFileDecoder SHALL decode the audio track from the input file into 16 kHz mono PCM Float32 samples, matching the format expected by the transcription engines.
4. THE AudioFileDecoder SHALL use AVFoundation (`AVAssetReader` + `AVAssetReaderTrackOutput`) for all decoding, requiring no additional dependencies.
5. IF the input file does not exist, THEN wispr-cli SHALL print a descriptive error message to stderr and exit with a non-zero status code.
6. IF the input file has no audio track, THEN wispr-cli SHALL print a descriptive error message to stderr and exit with a non-zero status code.
7. IF the input file format is not supported by AVFoundation, THEN wispr-cli SHALL print a descriptive error message to stderr and exit with a non-zero status code.

### Requirement 3: Model Discovery and Selection

**User Story:** As a user, I want the CLI to use models I have already downloaded via the GUI app so that I do not need to download them again.

#### Acceptance Criteria

1. THE wispr-cli SHALL read models from the GUI_App's sandboxed Shared_Models_Directory. Because the GUI_App runs inside the App Sandbox, its models are stored under `~/Library/Containers/<bundle-id>/Data/Library/Application Support/wispr/models/`. The non-sandboxed wispr-cli SHALL resolve this container path so that it reads the same models the GUI_App downloaded, without requiring the user to copy or move files.
2. THE wispr-cli SHALL accept a `--model <name>` option to specify which downloaded model to use for transcription.
3. IF no `--model` option is provided, THE wispr-cli SHALL use the model persisted as active in the GUI_App's UserDefaults domain (`com.stormacq.mac.wispr`, key: `activeModelName`), accessed via `UserDefaults(suiteName:)`.
4. IF no `--model` option is provided AND no active model is found in UserDefaults, THE wispr-cli SHALL print a descriptive error message to stderr and exit with a non-zero status code.
5. IF the specified model is not downloaded, THEN wispr-cli SHALL print an error message listing available downloaded models and exit with a non-zero status code.
6. THE wispr-cli SHALL accept a `--list-models` flag that prints all downloaded models with their names and sizes, download status, then exits.

### Requirement 4: Transcription and Output

**User Story:** As a user, I want the CLI to transcribe files and print the result to stdout so that I can pipe it to other tools or redirect it to a file.

#### Acceptance Criteria

1. WHEN wispr-cli receives a valid file path and a valid model, IT SHALL decode the audio, load the model, transcribe the audio, and print the transcribed text to stdout.
2. THE wispr-cli SHALL accept a `--output <file>` option to specify an output file path. WHEN `--output` is specified, THE wispr-cli SHALL write the transcribed text to the specified file and SHALL NOT write it to stdout.
3. THE wispr-cli SHALL accept a `--language <code>` option to specify the transcription language (e.g., `en`, `fr`, `ja`).
4. IF no `--language` option is provided, THE wispr-cli SHALL use automatic language detection.
5. THE wispr-cli SHALL print only the transcribed text to stdout, with no additional formatting, headers, or metadata, unless a verbose flag is set.
6. THE wispr-cli SHALL print progress and diagnostic messages to stderr so they do not interfere with stdout piping.
7. THE wispr-cli SHALL accept a `--verbose` flag that prints model loading progress, audio duration, and transcription timing to stderr.
8. THE wispr-cli SHALL exit with status code 0 on success and a non-zero status code on any error.
9. THE wispr-cli SHALL perform all transcription locally on-device, consistent with the GUI_App's privacy guarantees.

### Requirement 5: CLI Usage and Help

**User Story:** As a user, I want clear usage instructions so that I can quickly learn how to use the CLI.

#### Acceptance Criteria

1. THE wispr-cli SHALL accept a `--help` flag that prints usage information to stdout and exits with status code 0.
2. THE usage information SHALL include: a synopsis line, a description of each option, supported file formats, and an example invocation.
3. THE wispr-cli SHALL accept a `--version` flag that prints the version string (matching the GUI_App's version) and exits with status code 0.
4. WHEN invoked with no arguments and no piped input, THE wispr-cli SHALL print the usage information to stderr and exit with a non-zero status code.

### Requirement 6: CLI Installation from GUI App

**User Story:** As a user, I want an easy way to install the CLI to my PATH from within the Wispr app, so I can use it from any terminal session.

#### Acceptance Criteria

1. THE GUI_App's menu SHALL include an "Install Command Line Tool..." item only WHEN the CLI symlink at `/usr/local/bin/wispr` does not exist or does not point to the correct binary.
2. WHEN the user selects "Install Command Line Tool...", THE GUI_App SHALL display a dialog explaining the installation and showing the exact shell command to run.
3. THE displayed command SHALL create a symbolic link from `/usr/local/bin/wispr` to the `wispr-cli` binary inside the app bundle.
4. THE dialog SHALL include a "Copy Command" button that copies the shell command to the clipboard.
5. THE GUI_App SHALL NOT attempt to execute the symlink creation itself, as the sandboxed app cannot write to `/usr/local/bin/`.

### Requirement 7: Long File Handling

**User Story:** As a user, I want to transcribe long recordings (meetings, podcasts) without the CLI producing truncated results.

#### Acceptance Criteria

1. FOR audio files of any duration, THE wispr-cli SHALL decode the full audio and pass it to the transcription engine in a single call.
2. THE wispr-cli SHALL NOT perform its own chunking or overlap deduplication. The transcription engines (WhisperKit and Parakeet/FluidAudio) have built-in chunk processors with frame-aligned boundaries, mel spectrogram context, and proper token deduplication that produce significantly better results than external chunking.
3. THE AudioFileDecoder MAY retain a chunked decoding API (`decodeChunked`) for future use, but the CLI SHALL NOT use it for transcription.

### Requirement 8: Shared Code Between CLI and GUI

**User Story:** As a developer, I want the CLI and GUI to share transcription logic so that behavior is consistent and code is not duplicated.

#### Acceptance Criteria

1. THE AudioFileDecoder SHALL be implemented as a reusable component accessible to both the CLI_Target and the GUI_App target.
2. THE CLI_Target SHALL link the same WhisperKit and FluidAudio frameworks embedded in the app bundle.
3. THE CLI_Target SHALL reuse the existing `TranscriptionEngine` protocol and engine implementations (`WhisperService`, `ParakeetService`, `CompositeTranscriptionEngine`).
4. THE CLI_Target SHALL reuse the existing `ModelInfo`, `TranscriptionResult`, and `TranscriptionLanguage` model types.
5. Shared source files SHALL be added to both targets' membership in the Xcode project rather than duplicated.
