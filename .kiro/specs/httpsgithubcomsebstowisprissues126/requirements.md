# Export transcripts to note apps, starting with Obsidian (issue #126)

## Goal

When a meeting transcript is saved, Wispr can also write it as a Markdown file into a folder the user picked, such as an Obsidian vault. The feature is off by default. Nothing changes for users who do not turn it on.

The export is built around a small "destination" idea so other Markdown-based note apps can be added later by adding one entry, with no change to the exporter or Settings layout. Obsidian is the only destination in this spec. Nothing else is built now.

Scope: meeting transcripts only (the ones `TranscriptStore.save` writes today). Dictation text is inserted into the focused app and is not stored, so it is out of scope.

## Acceptance criteria

### Destinations (the extension point)

- A destination is a small value with a stable id (`obsidian`), a display name ("Obsidian"), and a way to detect whether the app is installed. The list of known destinations is one array in code. Obsidian is its only entry.
- Obsidian is detected by asking `NSWorkspace` for an app with bundle identifier `md.obsidian`. Detection sits behind an injectable check so tests can fake it.
- Settings shows the export section only when at least one known destination is detected. It is checked each time Settings opens. With no detected destination, nothing is shown and nothing is written.
- If a destination is uninstalled after setup, its settings are kept but it is hidden and not exported to. The export resumes if the app comes back.
- Each destination keeps its own settings (on/off, folder bookmark, subfolder, frontmatter), stored per destination id, so a second destination later does not share or overwrite them.

### Settings

- For each detected destination, Settings has an "Export to <name>" section with an on/off toggle (default off), a "Choose folder…" button that shows the chosen path, a "Clear" button, an optional "Subfolder" field, and an "Include frontmatter" toggle (default on).
- The chosen folder is stored as a security-scoped bookmark, following the pattern in `TranscriptLocation`, so it works in the sandbox and survives relaunch.
- The subfolder (for example `Transcripts`) is created inside the chosen folder when missing. Path separators and `..` are rejected.
- If the bookmark is stale, the export is skipped and Settings shows "Folder unavailable. Choose it again."

### Export behaviour

- When a destination is detected and switched on, saving a meeting transcript writes one `.md` file to its folder. The JSON transcript in the app's own storage is still written as before.
- The file name is `yyyy-MM-dd-HH-mm.md` from the meeting start time, plus the title slug when there is a title. If the name exists, a numeric suffix is added. Existing files are never overwritten.
- The Markdown is plain and does not depend on the destination. With frontmatter on, the file starts with YAML holding `title`, `date` (ISO 8601 local time), `source: wispr`, `duration` and `speakers`. Values are quoted so titles with `:` or `"` stay valid YAML.
- The body is `# <title>` followed by each entry as `**Speaker** (mm:ss): text`, in order. Speaker names are the user-renamed ones when set.
- If the export fails (folder gone, no permission, disk full), the meeting is still saved normally. The user sees a non-blocking notification and the error is logged. Recording is never interrupted.
- Renaming a transcript in the history does not rewrite or move exported files.

### Tests

- Detection with an injected checker (installed and missing).
- Markdown rendering, with and without frontmatter, including special characters in the title.
- File naming and collision suffixes.
- Subfolder validation.
- A failing export does not fail the save.
- Settings for one destination id do not affect another (tested with a fake second destination).

## Out of scope

- Any destination other than Obsidian, and any UI to add destinations.
- Non-Markdown formats, Obsidian URI or plugin integration, and per-app Markdown flavours.
- Exporting dictation text.
- Re-exporting or syncing past transcripts, or updating a file after export.
- Audio files.
