# Tasks: export meeting transcripts to Obsidian (issue #126)

Quick spec: no design.md. Each task is small and ends with a build and its tests passing. Code goes in `Sources/WisprApp`, tests in `wisprTests` (Swift Testing: `@Suite`, `@Test`, `#expect`). Follow the style of `TranscriptLocation.swift` and `TranscriptStore.swift`.

- [x] 1. Destinations list
  - Add `Services/TranscriptExportDestination.swift` with `struct TranscriptExportDestination` (`id`, `displayName`, `bundleIdentifier`) and `static let all = [obsidian]`. Obsidian: id `obsidian`, bundle id `md.obsidian`.
  - Add `protocol AppInstallDetecting` with `isInstalled(bundleIdentifier:) -> Bool` and a `NSWorkspace` implementation (`urlForApplication(withBundleIdentifier:) != nil`).
  - Add `static func detected(using:)` returning the destinations whose app is installed.
  - Tests (`TranscriptExportDestinationTests`): fake detector returns installed and missing; `detected` filters correctly.

- [x] 2. Per-destination settings
  - In `SettingsStore`, add per-destination values keyed by destination id: enabled (default false), folder bookmark (`Data?`), subfolder (`String`, default empty), include frontmatter (default true). Store them in `UserDefaults` under keys like `transcriptExport.<id>.enabled`. Include them in the reset-to-defaults path and in `init(defaults:)` loading, matching how `transcriptsFolderBookmark` is handled.
  - Tests in `SettingsStoreTests`: defaults, round trip, reset, and a fake id `other` does not change `obsidian` values.

- [x] 3. Markdown rendering
  - Add `Services/TranscriptMarkdownRenderer.swift`: `static func render(_ transcript: MeetingTranscript, includeFrontmatter: Bool) -> String`.
  - Frontmatter: `title` (title, or "Meeting <date>" when none), `date` (ISO 8601 local), `source: wispr`, `duration` (`formattedDuration`), `speakers` (resolved with `displayName(for:)`). Quote and escape every string value (`"` and `\`). Newlines in a title become spaces.
  - Body: `# <title>`, then one line per entry: `**Speaker** (mm:ss): text`, where mm:ss is the offset from `startTime`.
  - Tests: with and without frontmatter, title with `:` and `"`, renamed speakers, no title, offset formatting.

- [x] 4. File naming and writing
  - Add `Services/TranscriptExporter.swift` (`nonisolated enum`). `static func fileName(for:)` gives `yyyy-MM-dd-HH-mm` plus `-<title slug>` when titled. Reuse the slug logic from `TranscriptStore` (make the existing helper `internal` instead of copying it).
  - `static func validate(subfolder:)` rejects `/`, `\`, `..` and absolute paths.
  - `static func write(markdown:named:to folder:subfolder:)` creates the subfolder when missing and picks a free name by adding `-2`, `-3`, … It never overwrites.
  - Tests: naming with and without title, collision suffixes in a temp directory, subfolder validation, subfolder creation.

- [x] 5. Folder access
  - Add the folder-access part to `TranscriptExporter`: `makeBookmark(for:)` and `withFolder(bookmark:_:)`, which resolves the security-scoped bookmark, calls `startAccessingSecurityScopedResource()`, runs the closure, and always calls `stop…`. Return the refreshed bookmark when stale; report a stale or unusable bookmark as a typed error.
  - Reuse the approach in `TranscriptLocation.makeBookmark` and `activate`. Do not add a second always-open scope.
  - Tests: temp-directory bookmark round trip (non-sandboxed test run), unusable bookmark gives the error.

- [x] 6. Export on save
  - Add `@MainActor func exportIfConfigured(_ transcript: MeetingTranscript)` on `TranscriptExporter` (or a small `TranscriptExportCoordinator`). For each detected destination that is enabled and has a bookmark: render, then write inside `withFolder`. Detection and settings are injected so tests can fake them.
  - Never throw to the caller. On failure, log with `Log.stateManager.error` and post one non-blocking notification (reuse the pattern in `MeetingNotificationService`). On a stale bookmark, clear nothing; set a flag Settings reads to show "Folder unavailable. Choose it again."
  - Call it from both save sites in `MeetingStateManager` (`stopMeeting` and `finalizeForTermination`) right after `TranscriptStore.save(transcript)` returns a URL. Empty transcripts are not exported.
  - Tests: enabled and detected writes a file; disabled, not detected, or no folder writes nothing; a failing write does not change the result of the save; the JSON file is still written.

- [x] 7. Settings UI
  - In `UI/Settings/SettingsView.swift`, add a new `exportSection` (its own `Section` with a `SectionHeader`, same style as the others) in the `Form` right after `meetingSection`. It is not placed inside the Meeting section. For each destination from `detected(using:)` (checked on appear), show "Export to <name>": toggle, "Choose folder…" (`NSOpenPanel`, directories only, then store the bookmark), the chosen path, "Clear", a "Subfolder" field with inline error from `validate`, and an "Include frontmatter" toggle.
  - Show "Folder unavailable. Choose it again." when the stale flag is set. Hide the whole section when nothing is detected.
  - Add `AccessibilityHints` entries and labels, matching the existing controls.
  - Tests in `SettingsViewTests`: section hidden with no detected destination, shown with Obsidian detected (injected detector).

- [ ] 8. Docs and final checks
  - Add a short "Export to Obsidian" paragraph to `README.md` (what is written, where, that it is off by default and only appears when Obsidian is installed).
  - Run the CI `xcodebuild` build from `.github/workflows` and the new test suites. Run `swift test` only if it does not hang on this host; report if skipped.
  - Manual check on a Mac with Obsidian installed: pick a vault, record or stop a short meeting, confirm the `.md` file opens in Obsidian with valid properties.
