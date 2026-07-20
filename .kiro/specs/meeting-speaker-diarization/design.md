# Speaker Recognition (Diarization) for Meeting Transcripts

## Context

Meeting transcription shipped in v1.10.0 (PR #63). It separates speakers by **audio source**: microphone → "You", system audio → "Others". This works for a 1-on-1 call, but in real meetings the "Others" track contains 2–N remote participants and the UI lumps them all under a single green "Others" badge.

The goal is to extend the existing meeting feature with **real speaker diarization on the system-audio ("Others") track only**, so the live transcript shows distinct labels (Speaker 1, Speaker 2, …) for remote participants. The mic track keeps the simple "You" label — your own voice never needs clustering, and keeping that invariant preserves the privacy-friendly source-based split for your own audio.

Decisions:
- **Scope**: only the system-audio (Others) track is diarized. Mic stays "You".
- **Engine**: FluidAudio's `SortformerDiarizer` (already a dependency at 0.13.4 — ships streaming diarization with up to 4 speaker slots, runs on ANE, ~11% DER on DI-HARD III).
- **Speaker count**: auto-detect, no UI input. Labels rendered as `Speaker 1…N`.
- **Timing**: real-time during the meeting (matches existing live-transcript UX).

This is shipped behind the existing "experimental" framing of the meeting feature.

## Approach

Add a `MeetingDiarizer` actor that wraps `FluidAudio.SortformerDiarizer`, consumes the same system-audio chunks the transcription pipeline already consumes, and produces a timeline of `(startTime, endTime, speakerId)`. When a system-audio transcription chunk completes, attribute its text to the dominant speaker over that chunk's time window using the timeline.

Why this shape: the existing `MeetingStateManager` already runs `transcribeSystemAudio()` and `transcribeMicAudio()` inside a `withTaskGroup`. A new sibling task `runSystemDiarization()` reading the same audio stream is a natural fit. Sortformer is streaming (low latency, ANE-resident), and 4 speaker slots covers the overwhelming majority of meetings. For >4 we degrade gracefully to "Speaker 4+".

### Required code paths

**1. Data model — `Sources/WisprApp/Models/MeetingTranscript.swift`**

Replace the closed `MeetingSpeaker` enum with a richer type that preserves the existing `.you` / `.others` semantics while allowing per-speaker indices on the others side:

```swift
enum MeetingSpeaker: Sendable, Equatable, Hashable {
    case you
    case others(speakerIndex: Int?)  // nil = unknown / not yet diarized
}
```

Add a `displayName: String` computed property: `.you → "You"`, `.others(nil) → "Others"`, `.others(0) → "Speaker 1"`, `.others(1) → "Speaker 2"`, etc.

**Index convention (explicit):** the stored `speakerIndex` is **always 0-based** internally — this matches the index used by the color palette below, by Sortformer's slot IDs, and by log output. The **+1 transform happens only inside `displayName`**, so logs and code never disagree with each other; only the user-visible string is 1-based. Every call site that sees an index sees the 0-based form.

Update `asPlainText()` to use `displayName`.

Reasoning: keeping the case-based enum (rather than renaming to `speakerLabel: String?`) means existing call sites (`MeetingStateManager.transcribeMicAudio`/`transcribeSystemAudio`, the test fakes, `MeetingTranscriptView`) flip with minimal churn, and pre-diarized "Others" entries (when system audio is captured before the diarizer warms up) still render cleanly.

**2. New actor — `Sources/WisprApp/Services/MeetingDiarizer.swift`**

```swift
actor MeetingDiarizer {
    func warmUp() async throws
    func ingest(_ chunk: [Float], at startTime: TimeInterval) async
    func dominantSpeaker(in window: ClosedRange<TimeInterval>) async -> Int?
    func reset() async
}
```

Internals:
- Holds a `SortformerDiarizer` from FluidAudio (config: default = 4 speaker slots).
- `warmUp()` downloads/loads Sortformer CoreML model lazily on first meeting start (mirror the existing model-download pattern used for Whisper/Parakeet — the `WisprCore` layer already has download progress plumbing).
- `ingest()` feeds samples into the streaming diarizer with cumulative wall-clock time; the diarizer's `timeline` accumulates `TimedSpeakerSegment`s.
- `dominantSpeaker(in:)` queries the timeline for the speaker label that occupies the most time in the requested window, returning a stable 0-indexed `Int` (mapping Sortformer's internal slot ID to a per-meeting monotonically assigned index).

**3. Wire-in — `Sources/WisprApp/Services/MeetingStateManager.swift`**

- Inject `MeetingDiarizer?` (optional so existing tests that don't care can pass `nil`).
- In `startMeeting()`, call `await diarizer?.warmUp()` before flipping state to `.recording`. On failure, log and continue (mic-only fallback already handles this style of degradation).
- Refactor system-audio handling so a single consumer reads the audio stream, passes each chunk to **both** the diarizer (`ingest`) and the transcription engine, then resolves the speaker before appending the entry:

```swift
for await (chunk, chunkStart) in audioStream {  // chunkStart is provided by MeetingAudioEngine
    await diarizer?.ingest(chunk, at: chunkStart)
    let result = try await transcriptionEngine.transcribe(chunk, language: language)
    let chunkEnd = chunkStart + Double(chunk.count) / Double(MeetingAudioEngine.sampleRate)
    let speakerIdx = await diarizer?.dominantSpeaker(in: chunkStart...chunkEnd)
    transcript.entries.append(
        MeetingTranscriptEntry(speaker: .others(speakerIndex: speakerIdx), text: ...)
    )
}
```

**Timestamp source.** Chunk-start timestamps must come from the audio engine, not from `Date()`, so they line up exactly with what the diarizer sees. `MeetingAudioEngine` already chunks at exactly 80 000 samples and is the single source of truth for the system-audio sample rate (currently 16 kHz, hardcoded in the engine itself). Rather than dividing sample counts in the consumer, the engine should:

- Expose a `static let sampleRate: Int = 16_000` constant (or already-existing equivalent) — this is the *only* place the value lives.
- Change the system-audio stream from `AsyncStream<[Float]>` to `AsyncStream<(samples: [Float], startTime: TimeInterval)>`, computing `startTime` as `cumulativeSamples / Double(sampleRate)` inside the engine itself.

This eliminates the duplicated `16000` literal in the consumer and means a future change to the engine's sample rate (e.g. if Sortformer ever requires a different rate) flips one constant.

**Cold-start handling.** The streaming Sortformer model needs at least a few hundred milliseconds of audio before its timeline is populated, so `dominantSpeaker(in:)` will legitimately return `nil` for the first one or two chunks of every meeting (chunk size ~5 s, so this is the first 5–10 s). This is expected and not a bug; pending entries simply render as plain "Others" until the diarizer catches up. The renderer already handles `.others(nil)` cleanly via `displayName`.

If users find the warmup gap too jarring later, the next iteration can buffer those entries and retro-attribute them once the timeline contains the relevant window — but that adds reorder/flicker complexity, so v1 just lives with the gap and documents it in the release notes.

`transcribeMicAudio` does NOT change — it keeps producing `MeetingSpeaker.you`.

`stopMeeting()` calls `await diarizer?.reset()` after capture stops.

**4. UI — `Sources/WisprApp/UI/Meeting/MeetingTranscriptView.swift`**

Update `transcriptRow()` (around `MeetingTranscriptView.swift:181`):
- Use `entry.speaker.displayName` instead of `entry.speaker.rawValue`.
- Replace the binary blue/green color rule with a small color palette — `you → .blue`, `others(0) → .green`, `others(1) → .orange`, `others(2) → .purple`, `others(3) → .pink`, `others(nil) or 4+ → .gray`. Define this in a private helper to keep the view tidy.

No changes to the floating window panel layout — speaker labels already have a 48 pt column. Optionally widen to 56 pt to accommodate "Speaker 4".

**5. Settings — `Sources/WisprApp/Services/SettingsStore.swift`**

Add one `Bool` toggle following the existing `didSet`/`isLoading` pattern (see `handsFreeMode`):

```swift
var meetingDiarizationEnabled: Bool { didSet { ... } }
```

**Default: `false`, explicit opt-in.** The setting starts off and never flips automatically. The Settings panel (or the meeting window's first-run state) shows a row "Identify individual remote speakers (experimental)" with a toggle; turning it on for the first time triggers the Sortformer model download with a progress indicator, then enables diarization for subsequent meetings. This avoids the surprising "feature suddenly appeared mid-session" UX of an auto-enable on download.

**6. Tests — `wisprTests/`**

- `MeetingDiarizerTests.swift` (new): inject a fake/stub `SortformerDiarizer` (or test against a recorded short clip with known speaker boundaries) verifying `dominantSpeaker(in:)` returns the expected index.
- Extend `MeetingStateManagerTests.swift` to inject a stub `MeetingDiarizer` whose `dominantSpeaker(in:)` returns scripted values; assert that system-audio entries land with the right `.others(speakerIndex:)`. The existing `FakeMeetingTranscriptionEngine` pattern (referenced at `MeetingStateManagerTests.swift:291`) is the model.
- Update existing tests that instantiate `MeetingTranscriptEntry(speaker: .others, …)` to use the new associated-value form: `.others(speakerIndex: nil)`.

### Files that need editing (representative list)

| File | Change |
|------|--------|
| `Sources/WisprApp/Models/MeetingTranscript.swift` | Promote `MeetingSpeaker` enum to associated-value form, add `displayName` |
| `Sources/WisprApp/Services/MeetingDiarizer.swift` | **New** actor wrapping `SortformerDiarizer` |
| `Sources/WisprApp/Services/MeetingStateManager.swift` | Inject diarizer, route system-audio chunks through ingest+dominantSpeaker, warmUp on start |
| `Sources/WisprApp/Services/MeetingAudioEngine.swift` | Yield chunks with cumulative-time metadata (or expose sample counter) so caller can compute window timestamps |
| `Sources/WisprApp/UI/Meeting/MeetingTranscriptView.swift` | Use `displayName`; expand color palette |
| `Sources/WisprApp/Services/SettingsStore.swift` | Add `meetingDiarizationEnabled` toggle |
| `Sources/WisprApp/wisprApp.swift` | Construct `MeetingDiarizer` and pass into `MeetingStateManager` |
| `wisprTests/MeetingDiarizerTests.swift` | **New** unit tests |
| `wisprTests/MeetingStateManagerTests.swift` | Stub diarizer, update `MeetingSpeaker` callsites |
| `wisprTests/MeetingAudioEngineTests.swift` | Update if the chunk yield signature changes |
| `.kiro/specs/meeting-transcription/design.md` | Update §"Speaker Separation Strategy" to note diarization on Others track |

### Reused existing utilities

- **Model download/progress plumbing**: the WhisperKit/Parakeet model-download flow under `WisprCore` already streams progress to UI; reuse the same pattern for Sortformer's CoreML model (`SortformerModels.load(mainModelPath:)` takes a URL).
- **Permission flow**: Screen Recording permission already gates system-audio capture in `MeetingAudioEngine`. Diarization runs only when the system-audio path is active, so no new permission prompts.
- **Logging**: `Log.stateManager`, `Log.audioEngine` categories already exist; add a `Log.diarizer` peer.
- **Actor + AsyncStream pattern**: matches `WhisperService`/`ParakeetService` shape exactly.

## Verification

End-to-end manual test (the only honest way to verify diarization quality):

1. `xcodebuild -scheme wispr -configuration Debug build` — verifies compile.
2. `xcodebuild -scheme wispr -configuration Debug test` — runs unit tests including the new `MeetingDiarizerTests` and updated `MeetingStateManagerTests`.
3. Launch the app, grant Screen Recording permission, start a meeting.
4. Play a YouTube interview clip (≥2 distinct speakers) through the system audio. Confirm:
   - Live transcript labels alternate between "Speaker 1" and "Speaker 2" with the correct color.
   - Switching to a 3-speaker podcast shows "Speaker 3".
   - Your own voice (mic) still labels as "You".
   - Stop the meeting → `Copy` produces text with the per-speaker labels.
5. Toggle `meetingDiarizationEnabled` off in Settings → next meeting falls back to plain "Others" labels (regression check). On a fresh install the toggle is off; flipping it on triggers the model download dialog before the next meeting can use it.
6. Try with a meeting where Screen Recording permission is denied → mic-only path still works, no diarizer crashes.

CPU/ANE check: monitor Activity Monitor during a 5-min meeting; Sortformer should stay on ANE with negligible CPU. If CPU spikes, fall back to checking that `numSpeakers = 4` and chunkDuration are at defaults.

## Out of Scope (deliberate)

- Renaming speakers ("Speaker 1 → Alice"). Add later if requested; needs UI + persistence.
- Cross-meeting speaker recognition (`SpeakerDatabase` / persistent embeddings).
- Diarizing the mic track.
- CLI tool diarization (`wispr-cli`) — app only for this iteration.
- More than 4 simultaneous speakers — Sortformer's hard cap; document in release notes.
