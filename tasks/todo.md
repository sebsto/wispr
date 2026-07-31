# Transcript storage & history management

Branch: `el-pedrito/meeting-transcript-history`
Commits: `2c18af7` → `d1cd4c7`

## Context

- App is sandboxed (`ENABLE_APP_SANDBOX = YES`) with `ENABLE_USER_SELECTED_FILES = readwrite`,
  so a user-picked folder is reachable **only** via a persisted security-scoped bookmark.
- `TranscriptStore.list()` filters on filename prefix `meeting-` + extension `json`.
  Any renaming scheme must preserve that or the history list goes blank.
- `TranscriptSummary.id == url`, and `TranscriptSelection.archived(URL)` keys selection by
  URL, so renaming a file invalidates selection identity and must be remapped.

---

## Feature 1 — Configurable transcripts folder in Settings — done

- [x] `TranscriptLocation` resolves the effective directory over a `Mutex`.
- [x] Folder persisted as a security-scoped bookmark; scope held for the process lifetime.
- [x] Stale bookmarks refreshed; unusable ones cleared, falling back to the default.
- [x] `TranscriptStore.directory` reads through it.
- [x] Settings: current path, `Change…` (NSOpenPanel), `Use Default`, `Open Folder`.
- [x] Existing files are **left in place** on change (decided). Settings copy says so.
- [x] Changes are broadcast so the history rescans and the folder watch re-arms.
- [x] 11 tests.

## Feature 2 — Multi-select delete in meeting history — done

- [x] Sidebar `List` selection is a `Set`; display still follows a single row.
- [x] `.live` excluded from destructive actions.
- [x] `delete(_ summaries:)` continues past individual failures and reports together.
- [x] Context menu shows `Delete N Transcripts…` inside a multi-selection; `⌫` too.
- [x] Confirmation dialog states the count.
- [x] 4 batch tests.

## Feature 3 — Rename in Wispr renames the file on disk — done

- [x] `meeting-<timestamp>-<slug>.json`, keeping the prefix so `list()` still matches.
- [x] Slug sanitiser: alphanumerics kept, other runs collapse to one dash, capped at 60
      with no edge separators.
- [x] `retitle` writes the JSON then renames, and remaps `selection` to the new URL.
- [x] 14 tests.

## Feature 4 — Sync history when files change in Finder — done

- [x] `TranscriptDirectoryWatcher` over `DispatchSource`, exposed as an `AsyncStream`.
- [x] Debounced — a single Finder action emits several vnode events.
- [x] Consumed by the sidebar, keyed on the folder so it re-arms on a folder change.
- [x] 4 tests covering real external create / delete / rename.
- Scoped to the meeting window: nothing is watched while it is closed, and opening it
  refreshes. The list is never stale on screen, but this is not a permanent watch.

## Reverted — renaming in Finder renaming the session in Wispr

Dropped on request (`d1cd4c7`), and it did not deserve to stay: the title lives in the
JSON while the filename carries only a lossy slug, so punctuation could not survive the
round trip; it wrote to files during what callers treat as a read-only scan; and it only
ran while the meeting window was open.

---

## Verification

- [x] `swift build` and `xcodebuild` (Release, ad-hoc signed — no valid signing identity
      on this machine) both clean.
- [x] Five consecutive full runs: 613 tests, no failure beyond the pre-existing
      `AudioEngine audio level stream terminates on stop` flake, which was confirmed
      against unmodified HEAD in a clean worktree.
- [x] Transcripts directory left byte-for-byte unchanged across those runs.
- [ ] **Manual, still open** — needs a UI session: the folder picker, ⌘/⇧-click range
      selection, and a full Finder round-trip. Not automatable here without a signing
      certificate.

## Bugs found while implementing

- `slug` could return 61 characters: the separator was appended before the length check.
- Settings read only non-observable statics, so the displayed path did not refresh after
  picking a folder. Now derived from the observable bookmark.
- The two new source files were missing from `project.pbxproj`. SwiftPM globs the
  directory so `swift build` passed while the Xcode app target — the shipping build —
  did not compile.
- Changing the folder left the history on the previous one, so every action pointed at
  the old location and the watch stayed armed there.
- The transcript suites share one real directory and run in parallel, while
  `TranscriptLocationTests` redirects it process-wide — a different test failed on almost
  every run. A `TestScoping` trait now serialises them.
- `MeetingStateManagerTests` identified its file by diffing the directory, so in parallel
  it mis-counted *and* deleted other suites' files.
- Test fixtures leaked into the real transcripts folder and then corrupted later runs,
  because tests looked sessions up by title and matched the orphans. Cleaned up; lookups
  are now keyed on URL, and start times come from a shared counter set in the year 2000.
- `startTime` is not usable as a key after a disk round trip: ISO-8601 encoding drops the
  sub-second component.
