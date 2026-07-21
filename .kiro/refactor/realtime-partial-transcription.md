# Real-Time Partial Transcription — Implementation Plan

## Goal

Add real-time "ghost text" during recording: as the user speaks, partial transcription text appears in the recording overlay, giving immediate visual feedback before the final transcription is produced. This is opt-in (off by default), only available for models that support it, and builds on top of the hands-free / EOU infrastructure that is now merged into `main` (originally PR #22).

> **Prerequisite (already satisfied on `main`):** This plan depends on the EOU streaming infrastructure — `TranscriptionResult.isEndOfUtterance`, `TranscriptionEngine.supportsEndOfUtteranceDetection()`, `ParakeetService.transcribeStreamWithEou(_:)`, and `StateManager.startEouMonitoringIfSupported()`. All of these exist on `main` today, so this plan is actionable from the current tree.

> **Module layout:** The project is organized as SPM targets, not a flat `wispr/` folder. Model/service/engine types live in the **`WisprCore`** target (`Sources/WisprCore/`); UI, `StateManager`, and `SettingsStore` live in the **`WisprApp`** target (`Sources/WisprApp/`). Types crossing the module boundary (`TranscriptionResult`, `ModelInfo`, `TranscriptionEngine`) are `public`, so any new fields/methods on them must also be `public`.

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
// Sources/WisprCore/Models/ModelInfo.swift
public nonisolated struct ModelInfo: Identifiable, Sendable, Equatable {
    // ... existing fields ...

    /// Whether this model supports real-time partial transcription results.
    public let supportsPartialResults: Bool

    // Default to false for backward compat
    public init(..., supportsPartialResults: Bool = false) { ... }
}
```

Set to `true` only for the `parakeetEou` model in `ParakeetService.availableModels()`.

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
// Sources/WisprCore/Services/TranscriptionEngine.swift
/// Whether the currently loaded model supports real-time partial transcription.
/// When true and the feature is enabled, transcribeStream() should invoke
/// partial result callbacks during processing.
func supportsPartialResults() async -> Bool
```

This mirrors the existing `supportsEndOfUtteranceDetection()` requirement already on the protocol.

- `WhisperService`: returns `false`
- `ParakeetService`: returns `true` when `activeModelName == .parakeetEou && eouManager != nil`
- `CompositeTranscriptionEngine`: forwards to active engine

### 4. TranscriptionEngine — partial text delivery mechanism

Two options were considered:

**Option A: Callback on TranscriptionEngine protocol** — Add a `setPartialResultCallback` method. This mirrors the FluidAudio API but adds protocol surface area.

**Option B: Extend TranscriptionResult with `isPartial` flag** — Yield partial results through the existing `transcribeStream` return stream. The stream already yields `TranscriptionResult` values; partial results are just intermediate yields with an `isPartial: true` flag.

**Decision: Option B.** It reuses the existing streaming infrastructure, requires no new protocol methods beyond the capability query, and the StateManager already consumes `transcribeStream` output for EOU monitoring. Partial results are naturally interleaved.

```swift
// Sources/WisprCore/Models/TranscriptionResult.swift — add isPartial flag
public nonisolated struct TranscriptionResult: Sendable, Equatable {
    public let text: String
    public let detectedLanguage: String?
    public let duration: TimeInterval
    public let isEndOfUtterance: Bool  // already on main
    public let isPartial: Bool         // NEW

    public init(text: String, detectedLanguage: String? = nil, duration: TimeInterval,
                isEndOfUtterance: Bool = false, isPartial: Bool = false) { ... }
}
```

> `isEndOfUtterance` is already present on `main` (verified in `Sources/WisprCore/Models/TranscriptionResult.swift`). Only `isPartial` is a new field. Because `TranscriptionResult` is `public` and consumed across the module boundary by `WisprApp`, the new field and updated initializer must remain `public`.

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

        // Register partial callback if requested.
        // `startTime` is an immutable `let` captured by value, so there is no
        // data race on it. The callback yields into the AsyncThrowingStream
        // continuation, which is itself thread-safe, so it is safe to fire from
        // whatever thread FluidAudio invokes it on.
        if emitPartialResults {
            await manager.setPartialCallback { [startTime] partialText in
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

    // On termination, cancel the processing task AND replace the partial
    // callback with a no-op so a lingering callback can't keep yielding to
    // this (now finished) continuation across sessions. Yielding to an
    // already-finished continuation is a safe no-op in Swift — not a crash —
    // but overwriting the callback releases the captured continuation and
    // avoids wasted work.
    //
    // NOTE (verified against FluidAudio 0.13.4): `StreamingEouAsrManager.reset()`
    // does NOT clear `partialCallback`, and `setPartialCallback(_:)` takes a
    // non-optional `@escaping PartialCallback` — there is no `nil` overload.
    // So we install a no-op closure rather than passing nil.
    continuation.onTermination = { [weak manager] _ in
        task.cancel()
        Task { await manager?.setPartialCallback { _ in } }
    }
    return stream
}
```

The `emitPartialResults` parameter is threaded through `transcribeStream()`. The protocol method signature stays the same — the engine reads the setting internally or we add it as a parameter.

**Decision:** Add `emitPartialResults: Bool` as a required (non-defaulted) parameter to the `transcribeStream` protocol requirement, and provide a two-argument convenience overload in a protocol extension that forwards with `emitPartialResults: false`. Swift protocol *requirements* cannot carry default argument values — the default lives in the extension overload, not on the requirement. Existing two-argument call sites bind to the extension overload and are unaffected.

```swift
// Sources/WisprCore/Services/TranscriptionEngine.swift — updated requirement
func transcribeStream(
    _ audioStream: AsyncStream<[Float]>,
    language: TranscriptionLanguage,
    emitPartialResults: Bool
) async -> AsyncThrowingStream<TranscriptionResult, Error>
```

With a convenience overload in the extension (this is the mechanism that preserves existing call sites — NOT a default argument on the requirement):
```swift
extension TranscriptionEngine {
    // Two-argument convenience overload. Existing callers keep compiling and
    // route here, which forwards to the three-argument requirement above.
    // No recursion: this overload has a DIFFERENT arity than the requirement
    // it calls, so `transcribeStream(_:language:)` dispatches to the
    // conforming type's `transcribeStream(_:language:emitPartialResults:)`.
    public func transcribeStream(
        _ audioStream: AsyncStream<[Float]>,
        language: TranscriptionLanguage
    ) async -> AsyncThrowingStream<TranscriptionResult, Error> {
        await transcribeStream(audioStream, language: language, emitPartialResults: false)
    }
}
```

This mirrors the existing `reloadModelWithRetry()` / `reloadModelWithRetry(maxAttempts:)` overload pair already in `TranscriptionEngine.swift`.

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
        // Single source of cleanup: `defer` guarantees the ghost text is
        // cleared on EVERY exit path — normal completion, EOU break, thrown
        // error, or cancellation. This avoids the "clear before EOU handling
        // AND again in catch" duplication and the stale-text-on-throw gap.
        defer { self.partialTranscriptionText = nil }
        do {
            let resultStream = await self.whisperService.transcribeStream(
                await self.audioEngine.captureStream,
                language: self.currentLanguage,
                emitPartialResults: emitPartials
            )

            var finalResult: TranscriptionResult?
            for try await result in resultStream {
                if result.isPartial {
                    // Update overlay text — this is the "ghost text".
                    // The whole task runs on @MainActor, so this mutation of
                    // the @MainActor StateManager property is isolation-safe;
                    // the partial value arrives via the AsyncThrowingStream
                    // (thread-safe hand-off), not via direct cross-actor access.
                    self.partialTranscriptionText = result.text
                    continue
                }
                if result.isEndOfUtterance {
                    finalResult = result
                    break
                }
            }

            // finalResult is nil if the stream ended without EOU (e.g. the
            // input audio stream closed first). That is a normal, non-error
            // exit — just return; do NOT force-unwrap. The existing EOU
            // handling already guards on `finalResult` being non-nil.
            guard let finalResult, !Task.isCancelled, self.appState == .recording else {
                return
            }
            // ... rest of EOU handling unchanged (uses finalResult) ...
        } catch {
            guard !Task.isCancelled else { return }
            Log.stateManager.warning("EOU monitoring failed: \(error.localizedDescription)")
        }
    }
}
```

> Because the entire monitoring task is annotated `@MainActor` and `StateManager` is `@MainActor @Observable`, every mutation of `partialTranscriptionText` (the `continue` path, the `defer`, and the explicit clears listed below) runs on the main actor. There is no cross-isolation access to synchronize.

Also clear `partialTranscriptionText` in `resetToIdle()`, `endRecording()`, and `cancelEouMonitoring()` so it is reset even when monitoring never started (e.g. push-to-talk, or a non-EOU model).

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

The overlay height needs to grow when partial text is present. Adjusting `overlayHeight` (a fixed `@ScaledMetric` of `72` in `RecordingOverlayView`) alone is **not sufficient**: `RecordingOverlayPanel.createPanel()` sizes both the `NSHostingView` and the `NSPanel` to a hard-coded `260 × 92` and never updates them, so the SwiftUI view would be clipped. Either reserve a taller fixed panel height up front, or resize the hosting view / panel when partial text toggles (see the RecordingOverlayPanel row in the Files to Change table).

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
| `Sources/WisprCore/Models/ModelInfo.swift` | Add `public let supportsPartialResults: Bool` property with default `false` in the `public init` |
| `Sources/WisprCore/Models/TranscriptionResult.swift` | Add `public let isPartial: Bool` property with default `false` in the `public init` |
| `Sources/WisprCore/Services/TranscriptionEngine.swift` | Add `supportsPartialResults() async -> Bool` requirement. Add `emitPartialResults: Bool` parameter to the `transcribeStream` requirement. Add the two-argument convenience overload in the protocol extension for backward compat. |

### Phase 2: Engine implementations

| File | Change |
|------|--------|
| `Sources/WisprCore/Services/ParakeetService.swift` | Set `supportsPartialResults: true` on EOU model in `availableModels()`. Implement `supportsPartialResults()`. Wire `setPartialCallback` (+ no-op reset in `onTermination`) in `transcribeStreamWithEou()` when `emitPartialResults` is true. |
| `Sources/WisprCore/Services/WhisperService.swift` | Implement `supportsPartialResults()` returning `false`. Add `emitPartialResults` parameter to `transcribeStream` (ignored). |
| `Sources/WisprCore/Services/CompositeTranscriptionEngine.swift` | Forward `supportsPartialResults()` to active engine. Forward `emitPartialResults` in `transcribeStream`. |

### Phase 3: Settings & state

| File | Change |
|------|--------|
| `Sources/WisprApp/Services/SettingsStore.swift` | Add `showRealtimeText: Bool` property, `Keys.showRealtimeText`, `Defaults.showRealtimeText = false`, init, `save()`, `load()`, and reset in `restoreDefaults()` |
| `Sources/WisprApp/Services/StateManager.swift` | Add `partialTranscriptionText: String?`. Update `startEouMonitoringIfSupported()` to pass `emitPartialResults` and handle partial results (with `defer`-based cleanup). Clear partial text in `resetToIdle()`, `endRecording()`, `cancelEouMonitoring()`. |

### Phase 4: UI

| File | Change |
|------|--------|
| `Sources/WisprApp/UI/RecordingOverlayView.swift` | Show `partialTranscriptionText` below audio level meter. Adjust the `overlayHeight` (`@ScaledMetric`, currently `72`) so the overlay grows when partial text is present. |
| `Sources/WisprApp/UI/RecordingOverlayPanel.swift` | **Changes required.** The panel and its `NSHostingView` are created with a *fixed* frame (`260 × 92`, hard-coded in `createPanel()`) and never resized. To show multi-line ghost text the panel must either (a) grow its content size when `partialTranscriptionText` becomes non-nil, or (b) reserve a fixed taller height up front. Pick one and wire it through `createPanel()` / `positionPanel(_:)`. |
| `Sources/WisprApp/UI/Settings/SettingsView.swift` | Add "Show Real-Time Transcription" toggle in general section, disabled when unsupported. |

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
| `setPartialCallback` not cleared between sessions | **Verified in FluidAudio 0.13.4: `StreamingEouAsrManager.reset()` does NOT clear `partialCallback`.** Mandatory mitigation: install a no-op callback (`setPartialCallback { _ in }`) in `continuation.onTermination`, as shown in section 5. There is no `nil` overload, so a no-op closure is the mechanism. This is required, not optional. |

## What This Does NOT Do

- Does not add Parakeet V3 streaming via `StreamingAsrManager` (separate, larger effort)
- Does not add WhisperKit `AudioStreamTranscriber` streaming (audio pipeline conflict)
- Does not expose word-level timestamps or confidence scores (future enhancement)
- Does not insert partial text into the target app — only displays in the overlay
- Does not work in push-to-talk mode (requires hands-free + EOU path)
