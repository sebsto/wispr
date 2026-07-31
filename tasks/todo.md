# Transcript storage & history management — 4 features

Branch: `el-pedrito/meeting-transcript-history`

## Context

- App is sandboxed (`ENABLE_APP_SANDBOX = YES`) with `ENABLE_USER_SELECTED_FILES = readwrite`,
  so a user-picked folder is reachable **only** via a persisted security-scoped bookmark.
- `TranscriptStore.directory` is currently hardcoded to `ModelPaths.transcripts`.
- `TranscriptStore.list()` filters on filename prefix `meeting-` + extension `json`.
  Any file-renaming scheme must preserve that contract or the history list goes blank.
- `TranscriptSummary.id == url`, and `TranscriptSelection.archived(URL)` keys selection by URL.
  Renaming a file therefore invalidates selection identity and must be remapped.

---

## Feature 1 — Configurable transcripts folder in Settings

- [ ] Add `TranscriptLocation` (nonisolated) to resolve the effective directory:
      custom bookmark if set, else `ModelPaths.transcripts`.
- [ ] Persist the folder as a **security-scoped bookmark** in `SettingsStore`
      (raw path is useless under sandbox after relaunch).
- [ ] Resolve + `startAccessingSecurityScopedResource()` once at launch, hold for app lifetime;
      handle stale bookmarks by falling back to default and surfacing a message.
- [ ] Point `TranscriptStore.directory` at `TranscriptLocation.current`.
- [ ] Settings UI: show current path, `Change…` (NSOpenPanel, directories only), `Reset to Default`.
- [ ] Existing files are **left in place** on change (decided: simpler). The Settings copy
      must say so, since the history list will then only show the new folder's contents.
- [ ] Tests: bookmark round-trip, fallback on stale/missing bookmark.

## Feature 2 — Multi-select delete in meeting history

- [ ] Sidebar `List` selection becomes `Set<TranscriptSelection>`.
- [ ] Keep single-selection semantics for *display*: exactly 1 archived row selected → load it;
      more than 1 → leave the viewer as-is and enable bulk actions.
- [ ] Exclude `.live` from any destructive action.
- [ ] `MeetingHistoryStore.delete(_ summaries:)` for batch delete; continue past individual
      failures and report a combined error.
- [ ] Context menu shows `Delete N Transcripts…` when the clicked row is inside a multi-selection.
- [ ] Bind `⌘⌫` to delete the current selection.
- [ ] Confirmation dialog states the count.
- [ ] Tests: batch delete, partial failure, `.live` never deleted.

## Feature 3 — Directional rename (history name → filename on disk)

- [ ] Filename scheme `meeting-<timestamp>-<slug>.json`, keeping the `meeting-` prefix
      so `list()` keeps matching; no title → `meeting-<timestamp>.json`.
- [ ] Slug sanitizer: strip `/` `:` and control chars, spaces → `-`, collapse repeats,
      truncate (~60 chars); empty result falls back to timestamp-only.
- [ ] `TranscriptStore.rename(at:title:) -> URL` with collision suffixing.
- [ ] `retitle` writes the JSON **and** renames the file, then remaps
      `selection` / `loadedURL` to the new URL so the open transcript stays open.
- [ ] Tests: slug sanitizing, collision handling, title cleared, selection remap.

## Feature 4 — Sync history when files are deleted in Finder

- [ ] `TranscriptDirectoryWatcher` over `DispatchSource.makeFileSystemObjectSource`
      on the transcripts directory, exposed as an `AsyncStream`.
- [ ] Debounce (~300 ms) — a single Finder move emits several vnode events.
- [ ] Consume in the sidebar's `.task` (view-scoped: no watching while the window is closed;
      `.task` already refreshes on appear).
- [ ] Re-arm when the watched directory is replaced or reconfigured (Feature 1).
- [ ] Deleting the transcript being viewed falls back to live (`refresh()` already does this).
- [ ] Tests: watcher fires on external delete, debounce coalesces bursts.

---

## Verification

- [ ] `xcodebuild` clean build
- [ ] Full test suite green
- [ ] Manual: change folder → transcripts move; rename → filename changes in Finder;
      delete in Finder → row disappears; multi-select delete removes all.

## Review

All four features implemented, `swift build` and `xcodebuild` clean, 611 tests run
(580 at HEAD, +31 new) with one pre-existing unrelated failure.

### What landed

- **Feature 1** — `TranscriptLocation` resolves the folder over a `Mutex`, holding the
  security-scoped bookmark for the process lifetime. `TranscriptStore.directory` now
  reads through it. Settings gained `Change…` / `Use Default` / `Open Folder` plus an
  inline warning when a saved folder cannot be used.
- **Feature 2** — sidebar `List` selection is a `Set`; display still follows a single
  row. `delete(_:)` takes a batch and continues past individual failures.
  Context menu and the Delete key act on the selection, Finder-style.
- **Feature 3** — `retitle` now writes the JSON *then* renames the file
  (`meeting-<timestamp>-<slug>.json`) and remaps `selection` to the new URL.
- **Feature 4** — `TranscriptDirectoryWatcher` over `DispatchSource`, consumed by
  `MeetingHistoryStore.watchForExternalChanges()` and scoped to the meeting window.

### Bugs the tests caught

- `slug` could return 61 characters: the separator was appended before the length
  check. Fixed by accounting for the separator up front.
- The Settings section read only non-observable statics
  (`TranscriptLocation.isCustom`, `TranscriptStore.directory`), so the displayed path
  would not refresh after picking a folder. Now derived from the observable
  `settingsStore.transcriptsFolderBookmark`.
- The two new source files were missing from `project.pbxproj`. SwiftPM globs the
  directory so `swift build` passed, but the Xcode app target — the shipping build —
  did not compile until they were registered.

### Notes

- Three existing retitle tests asserted against the pre-rename URL. Updated to follow
  the renamed file, which also makes them cover the rename.
- `AudioEngine audio level stream terminates on stop` fails in a full run and passes
  in isolation. Verified pre-existing by running the full suite in a clean worktree at
  HEAD, where it fails identically.

### Not verified

- Manual UI behaviour (folder picker, shift-click range select, Finder round-trip) was
  not exercised — the app cannot be launched from here without a signing certificate.
