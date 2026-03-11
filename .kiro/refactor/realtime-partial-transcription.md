# Real-Time Partial Transcription — Implementation Plan

## Goal

Add real-time "ghost text" during recording: as the user speaks, partial transcription text appears in the recording overlay, giving immediate visual feedback before the final transcription is produced. This is opt-in (off by default), only available for models that support it, and builds on top of the hands-free / EOU infrastructure from PR #22.

## Background — What the SDK Supports

### Parakeet EOU 120M (`StreamingEouAsrManager`)
- **`setPartialCallback(_ callback: @escaping PartialCallback)`** — fires after every audio chunk with the accumulated partial transcript as a `String`. This is the lowest-effort integration: one line to register, callback fires automatically during `process(audioBuffer:)`.
- Already used for streaming + EOU detection. Adding partial results is additive.

### Parakeet V3 (`StreamingAsrManager` — not currently used)
- Provides `transcriptionUpdates: AsyncStream<StreamingTranscriptionUpdate>` with `volatileTranscript` (may change) and `confirmedTranscript` (stable).
- Each `StreamingTranscriptionUpdate` includes `text`, `isConfirmed`, `confidence`, `tokenTimings`.
- Uses a sliding-window approach on the larger V3 model (~400 MB). Higher latency but richer output.
- **Out of scope for this plan.** Integrating `StreamingAsrManager` as a third operating mode for ParakeetService is a larger effort. This plan focuses on EOU partial results only. V3 streaming can be a follow-up.

### WhisperKit (`AudioStreamTranscriber`)
- Has streaming with partial/confirmed segments via `AudioStreamTranscriber`.
- However, it owns the audio pipeline internally (`audioProcessor.startRecordingLive()`), which conflicts with our `AudioEngine`. Integrating it would require either surrendering audio capture to WhisperKit or wiring up low-level components.
- **Out of scope for this plan.** Practical constraints make this a separate, larger effort.

## Scope

- **In scope:** Parakeet EOU 120M partial results via `setPartialCallback`
- **Out of scope:** WhisperKit streaming, Parakeet V3 `StreamingAsrManager`, word-level timestamps, confidence scores

## Design

### 1. ModelInfo — `supportsPartialResults` capability flag

Like `supportsEndOfUtteranceDetection()` on the protocol, we tag models that support partial results. Since the user asked for manual tagging in `ModelInfo` (like EOU), we add a stored property.

```swift
// ModelInfo.swift
struct ModelInfo: Identifiable, Sendable, Equatable {
    // ... existing fields ...

    /// Whether this model supports real-time partial transcription results.
    let supportsPartialResults: Bool

    // Default to false for backward compat
    init(..., supportsPartialResults: Bool = false) { ... }
}
```

Set to `true` only for `parakeetEou` in `ParakeetService.availableModels()`.

### 2. SettingsStore — `showRealtimeText` setting

```swift
// SettingsStore.swift
/// When true and the active model supports it, show partial transcription
/// text in the recording overlay as the user speaks.
/// Defaults to false.
var showRealtimeText: Bool {
    didSet { save() }
}
```

Add `Keys.showRealtimeText`, init to `false`, persist in `save()`/`load()`, reset in `restoreDefaults()`.

### 3. TranscriptionEngine — `supportsPartialResults()` query

```swift
// TranscriptionEngine.swift
/// Whether the currently loaded model supports real-time partial transcription.
/// When true and the feature is enabled, transcribeStream() should invoke
/// partial result callbacks during processing.
func supportsPartialResults() async -> Bool
```

- `WhisperService`: returns `false`
- `ParakeetService`: returns `true` when `activeModelName == .parakeetEou && eouManager != nil`
- `CompositeTranscriptionEngine`: forwards to active engine

### 4. TranscriptionEngine — partial text delivery mechanism

Two options were considered:

**Option A: Callback on TranscriptionEngine protocol** — Add a `setPartialResultCallback` method. This mirrors the FluidAudio API but adds protocol surface area.

**Option B: Extend TranscriptionResult with `isPartial` flag** — Yield partial results through the existing `transcribeStream` return stream. The stream already yields `TranscriptionResult` values; partial results are just intermediate yields with an `isPartial: true` flag.

**Decision: Option B.** It reuses the existing streaming infrastructure, requires no new protocol methods beyond the capability query, and the StateManager already consumes `transcribeStream` output for EOU monitoring. Partial results are naturally interleaved.

```swift
// TranscriptionResult.swift — add isPartial flag
struct TranscriptionResult: Sendable, Equatable {
    let text: String
    let detectedLanguage: String?
    let duration: TimeInterval
    let isEndOfUtterance: Bool  // from PR #22
    let isPartial: Bool         // NEW

    init(text: String, detectedLanguage: String? = nil, duration: TimeInterval,
         isEndOfUtterance: Bool = false, isPartial: Bool = false) { ... }
}
```

### 5. ParakeetService — wire up `setPartialCallback`

In `transcribeStreamWithEou()`, before the processing loop, register a partial callback that yields intermediate results:

```swift
private func transcribeStreamWithEou(
    _ audioStream: AsyncStream<[Float]>,
    emitPartialResults: Bool  // NEW parameter
) -> AsyncThrowingStream<TranscriptionResult, Error> {
    let (stream, continuation) = AsyncThrowingStream.makeStream(of: TranscriptionResult.self)
    let manager = self.eouManager

    let task = Task {
        guard let manager else {
            continuation.finish(throwing: WisprError.modelNotDownloaded)
            return
        }
        await manager.reset()
        let startTime = Date()

        // Register partial callback if requested
        if emitPartialResults {
            await manager.setPartialCallback { partialText in
                let trimmed = partialText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                continuation.yield(TranscriptionResult(
                    text: trimmed,
                    detectedLanguage: nil,
                    duration: Date().timeIntervalSince(startTime),
                    isPartial: true
                ))
            }
        }

        do {
            var eouDetected = false
            for await chunk in audioStream {
                try Task.checkCancellation()
                let buffer = Self.createPCMBuffer(from: chunk, sampleRate: 16000)
                _ = try await manager.process(audioBuffer: buffer)
                if await manager.eouDetected {
                    eouDetected = true
                    break
                }
            }
            let finalText = try await manager.finish()
            let trimmed = finalText.trimmingCharacters(in: .whitespacesAndNewlines)
            if eouDetected || !trimmed.isEmpty {
                continuation.yield(TranscriptionResult(
                    text: trimmed,
                    detectedLanguage: nil,
                    duration: Date().timeIntervalSince(startTime),
                    isEndOfUtterance: eouDetected
                ))
            }
            continuation.finish()
        } catch {
            continuation.finish(throwing: error)
        }
    }

    continuation.onTermination = { _ in task.cancel() }
    return stream
}
```

The `emitPartialResults` parameter is threaded through `transcribeStream()`. The protocol method signature stays the same — the engine reads the setting internally or we add it as a parameter.

**Decision:** Add an optional `emitPartialResults: Bool = false` parameter to `transcribeStream` on the protocol, defaulting to `false` so all existing call sites are unaffected.

```swift
// TranscriptionEngine.swift — updated signature
func transcribeStream(
    _ audioStream: AsyncStream<[Float]>,
    language: TranscriptionLanguage,
    emitPartialResults: Bool
) async -> AsyncThrowingStream<TranscriptionResult, Error>
```

With a default extension:
```swift
extension TranscriptionEngine {
    func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        await transcribeStream(audioStream, language: language, emitPartialResults: false)
    }
}
```

### 6. StateManager — surface partial text

Add a published property for the UI:

```swift
// StateManager.swift
/// Partial transcription text shown in the overlay during recording.
/// Updated in real-time when showRealtimeText is enabled and the model supports it.
/// Cleared when recording stops.
var partialTranscriptionText: String?
```

In `startEouMonitoringIfSupported()` (from PR #22), pass `emitPartialResults`:

```swift
private func startEouMonitoringIfSupported() async {
    let supportsEou = await whisperService.supportsEndOfUtteranceDetection()
    guard supportsEou else { return }

    let emitPartials = settingsStore.showRealtimeText
        && await whisperService.supportsPartialResults()

    eouMonitoringTask = Task { @MainActor [weak self] in
        guard let self else { return }
        do {
            let resultStream = await self.whisperService.transcribeStream(
                await self.audioEngine.captureStream,
                language: self.currentLanguage,
                emitPartialResults: emitPartials
            )

            var finalResult: TranscriptionResult?
            for try await result in resultStream {
                if result.isPartial {
                    // Update overlay text — this is the "ghost text"
                    self.partialTranscriptionText = result.text
                    continue
                }
                if result.isEndOfUtterance {
                    finalResult = result
                    break
                }
            }

            self.partialTranscriptionText = nil
            // ... rest of EOU handling unchanged ...
        } catch {
            self.partialTranscriptionText = nil
            guard !Task.isCancelled else { return }
            Log.stateManager.warning("EOU monitoring failed: \(error.localizedDescription)")
        }
    }
}
```

Clear `partialTranscriptionText` in `resetToIdle()`, `endRecording()`, and `cancelEouMonitoring()`.

### 7. RecordingOverlayView — display partial text

Add a text area below the audio level meter that shows `stateManager.partialTranscriptionText`:

```swift
// RecordingOverlayView.swift — in recordingContent
private var recordingContent: some View {
    VStack(spacing: 6) {
        HStack(spacing: 10) {
            Image(systemName: SFSymbols.recordingMicrophone)
                // ... existing microphone icon ...
            audioLevelMeter
        }

        if let partialText = stateManager.partialTranscriptionText {
            Text(partialText)
                .font(.caption)
                .foregroundStyle(theme.secondaryTextColor)
                .lineLimit(2)
                .truncationMode(.head)  // show most recent text
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        }
    }
    .padding(.horizontal, 20)
}
```

The overlay height may need to grow when partial text is present. Use `.fixedSize(horizontal: false, vertical: true)` or adjust `overlayHeight` conditionally.

### 8. SettingsView — toggle in General section

Add under the "General" section (not hotkey section — it's a display preference, not an input mode):

```swift
// SettingsView.swift — in generalSection
@Bindable var store = settingsStore
Toggle("Show Real-Time Transcription", isOn: $store.showRealtimeText)
    .disabled(!activeModelSupportsPartialResults)
    .accessibilityHint(
        "When enabled, shows partial transcription text in the recording overlay as you speak. " +
        "Only available with supported models."
    )
```

The toggle is disabled (grayed out) when the active model doesn't support partial results. Add a computed property:

```swift
private var activeModelSupportsPartialResults: Bool {
    whisperModels.first(where: { $0.id == settingsStore.activeModelName })?.supportsPartialResults ?? false
}
```

### 9. Non-EOU path — partial results without hands-free

Currently, partial results are only surfaced through the EOU monitoring task in `startEouMonitoringIfSupported()`, which only runs in hands-free mode. For push-to-talk users who also want to see ghost text, we have two options:

**Option A:** Only show partial text in hands-free mode (simpler, partial results are a natural complement to EOU).

**Option B:** Also start a streaming transcription in push-to-talk mode when `showRealtimeText` is enabled, purely for display purposes (no EOU behavior).

**Decision: Option A for now.** The partial callback on `StreamingEouAsrManager` requires the EOU streaming path, which is already active in hands-free mode. Enabling it in push-to-talk mode would require starting a parallel streaming session just for display, which adds complexity. The setting toggle should note this dependency: "Requires Hands-Free Mode and a supported model."

Update the disabled state:
```swift
.disabled(!activeModelSupportsPartialResults || !settingsStore.handsFreeMode)
```

And add helper text below the toggle when disabled:
```swift
if !settingsStore.handsFreeMode || !activeModelSupportsPartialResults {
    Text("Requires Hands-Free Mode and a supported model (Realtime 120M)")
        .font(.caption)
        .foregroundStyle(.secondary)
}
```

## Files to Change

### Phase 1: Data model & protocol changes

| File | Change |
|------|--------|
| `wispr/Models/ModelInfo.swift` | Add `supportsPartialResults: Bool` property with default `false` |
| `wispr/Models/TranscriptionResult.swift` | Add `isPartial: Bool` property with default `false` |
| `wispr/Services/TranscriptionEngine.swift` | Add `supportsPartialResults() async -> Bool` requirement. Add `emitPartialResults: Bool` parameter to `transcribeStream`. Add default extension for backward compat. |

### Phase 2: Engine implementations

| File | Change |
|------|--------|
| `wispr/Services/ParakeetService.swift` | Set `supportsPartialResults: true` on EOU model in `availableModels()`. Implement `supportsPartialResults()`. Wire `setPartialCallback` in `transcribeStreamWithEou()` when `emitPartialResults` is true. |
| `wispr/Services/WhisperService.swift` | Implement `supportsPartialResults()` returning `false`. Add `emitPartialResults` parameter to `transcribeStream` (ignored). |
| `wispr/Services/CompositeTranscriptionEngine.swift` | Forward `supportsPartialResults()` to active engine. Forward `emitPartialResults` in `transcribeStream`. |

### Phase 3: Settings & state

| File | Change |
|------|--------|
| `wispr/Services/SettingsStore.swift` | Add `showRealtimeText: Bool` property, key, init, save, load |
| `wispr/Services/StateManager.swift` | Add `partialTranscriptionText: String?`. Update `startEouMonitoringIfSupported()` to pass `emitPartialResults` and handle partial results. Clear partial text in `resetToIdle()`, `endRecording()`, `cancelEouMonitoring()`. |

### Phase 4: UI

| File | Change |
|------|--------|
| `wispr/UI/RecordingOverlayView.swift` | Show `partialTranscriptionText` below audio level meter. Adjust overlay sizing. |
| `wispr/UI/RecordingOverlayPanel.swift` | No changes expected (overlay already resizes based on content) |
| `wispr/UI/Settings/SettingsView.swift` | Add "Show Real-Time Transcription" toggle in general section, disabled when unsupported. Add `restoreDefaults()` reset. |

### Phase 5: Tests

| File | Change |
|------|--------|
| `wisprTests/StateManagerTests.swift` | Test partial text updates during EOU monitoring. Test partial text cleared on stop. |
| `wisprTests/CompositeTranscriptionEngineTests.swift` | Test `supportsPartialResults()` forwarding. |
| `wisprTests/SettingsStoreTests.swift` | Test `showRealtimeText` persistence and defaults. |
| New: `wisprTests/PartialTranscriptionTests.swift` | Integration test: mock engine emits partial results, verify StateManager surfaces them and clears on completion. |

## Execution Order

1. Add `supportsPartialResults` to `ModelInfo` (all existing inits get `false` default)
2. Add `isPartial` to `TranscriptionResult` (default `false`, no existing code affected)
3. Add `supportsPartialResults()` to `TranscriptionEngine` protocol + all conformances
4. Add `emitPartialResults` parameter to `transcribeStream` on protocol + default extension + all conformances
5. Wire `setPartialCallback` in `ParakeetService.transcribeStreamWithEou()`
6. Add `showRealtimeText` to `SettingsStore`
7. Add `partialTranscriptionText` to `StateManager`, update EOU monitoring
8. Update `RecordingOverlayView` to display partial text
9. Add toggle to `SettingsView`
10. Add tests
11. Build and run tests

Each step should compile independently.

## Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| `PartialCallback` fires on a non-main thread, but `partialTranscriptionText` is on `@MainActor` `StateManager` | The callback yields into an `AsyncThrowingStream` continuation (thread-safe). StateManager consumes on `@MainActor`. No direct cross-isolation access. |
| Partial text updates too frequently, causing UI jank | `setPartialCallback` fires per-chunk (160ms). At ~6 updates/sec this is fine for SwiftUI text updates. If needed, throttle with a `Date` comparison. |
| Overlay height changes cause visual jitter when partial text appears/disappears | Use `.animation(.easeInOut(duration: 0.2))` on the text transition. Consider a fixed reserved height for the text area when in partial-results mode. |
| User enables setting but switches to a non-EOU model | Toggle shows disabled state with explanatory caption. Setting value persists but has no effect — the `supportsPartialResults()` check in StateManager gates the behavior. |
| `setPartialCallback` not cleared between sessions | Call `manager.reset()` (already done) which should clear internal state. Verify in FluidAudio source that reset clears the callback, or explicitly set a nil callback on cleanup. |

## What This Does NOT Do

- Does not add Parakeet V3 streaming via `StreamingAsrManager` (separate, larger effort)
- Does not add WhisperKit `AudioStreamTranscriber` streaming (audio pipeline conflict)
- Does not expose word-level timestamps or confidence scores (future enhancement)
- Does not insert partial text into the target app — only displays in the overlay
- Does not work in push-to-talk mode (requires hands-free + EOU path)
