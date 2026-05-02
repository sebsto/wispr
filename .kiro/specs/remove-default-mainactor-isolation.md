# Remove Default @MainActor Isolation

## Status: Planned

## Problem

The project uses `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (Xcode) and `.defaultIsolation(MainActor.self)` (SPM), which applies `@MainActor` to every type by default. This forces ~30 pure data types, utilities, and CLI types to opt out with `nonisolated` annotations, even though they have no UI or main-thread requirements.

Every type that genuinely needs `@MainActor` already declares it explicitly. The default isolation adds no value — it only creates noise.

## Current State

### Types that need `@MainActor` (already explicit)

| Type | File | Why `@MainActor` |
|------|------|-------------------|
| `StateManager` | Sources/WisprApp/Services/StateManager.swift | `@Observable`, drives UI state |
| `SettingsStore` | Sources/WisprApp/Services/SettingsStore.swift | `@Observable`, UserDefaults, SMAppService |
| `HotkeyMonitor` | Sources/WisprApp/Services/HotkeyMonitor.swift | Carbon/CGEventTap callbacks, `@Observable` |
| `TextInsertionService` | Sources/WisprApp/Services/TextInsertionService.swift | AXUIElement, NSPasteboard, CGEvent |
| `TextCorrectionService` | Sources/WisprApp/Services/TextCorrectionService.swift | FoundationModels, `@Observable` |
| `SoundFeedbackService` | Sources/WisprApp/Services/SoundFeedbackService.swift | AVAudioPlayer |
| `UpdateChecker` | Sources/WisprApp/Services/UpdateChecker.swift | `@Observable`, drives menu updates |
| `PermissionManager` | Sources/WisprApp/Services/PermissionManager.swift | Opens System Settings, `@Observable` |
| `UIThemeEngine` | Sources/WisprApp/Utilities/UIThemeEngine.swift | Appearance monitoring, `@Observable` |
| `WisprAppDelegate` | Sources/WisprApp/wisprApp.swift | NSApplicationDelegate, window management |
| `MenuBarController` | Sources/WisprApp/UI/MenuBarController.swift | NSStatusItem, NSMenu |
| `RecordingOverlayPanel` | Sources/WisprApp/UI/RecordingOverlayPanel.swift | NSPanel subclass |
| All SwiftUI Views | Sources/WisprApp/UI/**/*.swift | `View` protocol infers `@MainActor` automatically |

### Types that do NOT need `@MainActor` (forced to opt out)

**WisprCore models** (currently `public nonisolated struct/enum`):
- `DownloadProgress`, `ModelInfo`, `ModelProvider`, `ModelStatus`
- `TranscriptionLanguage`, `TranscriptionResult`, `WisprError`

**WisprCore utilities** (currently `public nonisolated enum`):
- `Log`, `ModelPaths`

**WisprCore services** (custom actors — `actor` keyword overrides default):
- `WhisperService`, `ParakeetService`, `CompositeTranscriptionEngine`, `AudioFileDecoder`

**WisprApp models** (would need `nonisolated` if accessed cross-module):
- `AppStateType`, `AppUpdateInfo`, `AudioInputDevice`, `CorrectionStyle`
- `OnboardingStep`, `PermissionStatus`, `SemanticVersion`

**WisprApp utilities**:
- `FillerWordCleaner`, `SFSymbols`, `PreviewHelpers`

**WisprCLI** (headless CLI — no UI at all):
- `WisprCLI`, `CLIError`, `TranscribeConfig`, `DownloadedModelInfo`

## Proposed Change

1. Remove `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` from all Xcode build configurations in `project.pbxproj`
2. Remove `.defaultIsolation(MainActor.self)` from `Package.swift`
3. Remove all `nonisolated` annotations from WisprCore types (they become naturally nonisolated)
4. Remove `nonisolated` from `CLIError.description` in WisprCLI
5. Audit WisprApp files for any type that implicitly relied on default `@MainActor` without an explicit annotation — add explicit `@MainActor` where needed

## Risk Assessment

**Low risk for:**
- WisprCore: all types are either custom actors or `Sendable` value types. Removing default isolation just removes unnecessary `nonisolated` annotations.
- WisprCLI: no UI, no `@MainActor` needed anywhere.
- SwiftUI views: `View` protocol conformance infers `@MainActor` regardless of default isolation.
- Services with explicit `@MainActor`: no change needed.

**Medium risk for:**
- WisprApp non-View types that don't have explicit `@MainActor` but rely on the default. These need auditing:
  - Any `class` or `struct` in WisprApp that accesses `@MainActor`-isolated APIs without explicit annotation
  - Closures passed to AppKit APIs that assume main-thread execution
  - `@Observable` types that aren't explicitly `@MainActor` (if any exist)

## Verification Plan

1. Remove the settings
2. Build with `swift build` — fix any new errors (these reveal types that need explicit `@MainActor`)
3. Build with `xcodebuild -scheme wispr` — fix any new errors
4. Build with `xcodebuild -scheme wispr-cli` — should be clean
5. Run tests: `xcodebuild test -scheme wispr`
6. Manual smoke test: launch app, record, transcribe, check settings

## References

- [SE-0449: Allow nonisolated to prevent global actor inference](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0449-nonisolated-for-global-actor-cutoff.md) — the feature we're currently using as a workaround
- [Swift Forums: Question about Swift 6.2 Concurrency](https://forums.swift.org/t/question-about-swift-6-2-concurrency/82202) — exact same problem reported by others with SPM modules under default MainActor isolation
