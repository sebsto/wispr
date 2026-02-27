# Structured Concurrency in Wisp

## Policy
This project uses structured concurrency patterns (async let, TaskGroup, AsyncStream) throughout.

## Swift 6 Concurrency Defaults
**CRITICAL**: In Swift 6 with strict concurrency:
- **@MainActor is the default isolation** for all code unless explicitly marked otherwise
- When facing isolation errors, prefer adding **@MainActor** to functions/types
- Use **nonisolated(unsafe)** for properties that need to bypass isolation (e.g., non-Sendable types like WhisperKit)
- **IMPORTANT**: Adding @MainActor to test functions that interact with actors (like AudioEngine) will cause runtime crashes with "Incorrect actor executor assumption"
- **Solution**: Use `await` to access properties across actor boundaries instead of changing isolation
- Tests should match the isolation of the code they're testing (don't add @MainActor to tests for actor-isolated code)

## Why Structured Concurrency?
- Automatic task cancellation propagation
- Automatic error propagation
- Clear parent-child task relationships
- Guaranteed resource cleanup
- Prevents task leaks

## Task {} Usage in AsyncStream - Structured Pattern

### Pattern Used in PermissionManager and AudioEngine
Both components use `Task {}` inside `AsyncStream` closures. **This IS structured concurrency** because:

1. The Task is scoped to the AsyncStream's lifetime
2. When the AsyncStream is cancelled (consumer drops it), the task automatically cancels
3. No manual cleanup needed - the structured scope handles propagation

### Why Task {} is Needed Here
AsyncStream's closure-based API is **synchronous**, but we need **async/await** for:
- `Task.sleep` (PermissionManager polling)
- Calling async actor methods (AudioEngine callbacks)

Task {} is the idiomatic bridge from sync closures to async work while maintaining structure.

### PermissionManager Example (wispr/Services/PermissionManager.swift)

**Pattern** (updated to use `makeStream`):
```swift
func monitorPermissionChanges() -> AsyncStream<Void> {
    let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
    
    Task {
        defer { continuation.finish() }
        
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            checkPermissions()
            continuation.yield()
        }
    }
    
    return stream
}
```

**Why `makeStream` over closure-based init**:
- Avoids nonisolated closure capture issues (critical for actors, good practice for @MainActor)
- Continuation is a separate value — no closure capture ambiguity
- Consistent pattern across the codebase (AudioEngine uses the same approach)
- The `Task {}` inside still bridges from sync to async and is scoped to the stream's lifetime

### AudioEngine Example (wispr/Services/AudioEngine.swift)

AudioEngine uses two concurrency patterns:

**1. AsyncStream via `makeStream` (for audio level stream)**:
```swift
let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
self.levelContinuation = continuation
```

**Why `makeStream` is required for actors**:
- The closure-based `AsyncStream { continuation in }` init creates a **nonisolated** closure
- Capturing `self` (an actor) in a nonisolated closure causes actor executor crashes during teardown
- `makeStream` returns the continuation as a separate value — no closure capture needed
- Continuation is stored as actor state and cleaned up explicitly in `stopCapture()`/`cancelCapture()`

**2. Task {} in audio tap callback (bridging C callback to actor)**:
```swift
inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
    let bufferCopy = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
    Task {
        await self?.processAudioBufferData(bufferCopy, frameLength: UInt32(frameLength))
    }
}
```

**Why This IS Structured**:
- Task is scoped to the audio tap's lifetime
- Removed when tap is removed via `engine.inputNode.removeTap(onBus: 0)`
- Bridges from synchronous C callback to async actor method
- `[weak self]` prevents retain cycles
- `processAudioBufferData` guards on `isCapturing` flag to reject stale callbacks during teardown

## Avoiding Unstructured Task.init

### ❌ Anti-Pattern: Detached Task (WhisperService - FIXED)
**Previously had this problem**:
```swift
// ❌ WRONG: Creates detached/unstructured task
let downloadTask = Task<Void, Error> {
    // async work happens here, but isn't awaited
}
downloadTasks[model.id] = downloadTask
try await downloadTask.value  // Manual tracking required
```

**Problems**:
- Runs independently of function's scope
- Isn't automatically cancelled when downloadModel exits
- Requires manual tracking in dictionary
- Violates structured concurrency hierarchy

### ✅ Fixed: Pure Structured (WhisperService.downloadModel)
```swift
func downloadModel(...) async throws {
    // Concurrent download check (business logic requirement)
    guard downloadTasks[model.id] == nil else {
        throw WispError.modelDownloadFailed("Already downloading")
    }
    
    // ✅ PURE STRUCTURED: No Task creation - just do the work
    downloadTasks[model.id] = true  // Business logic tracking only
    defer { downloadTasks.removeValue(forKey: model.id) }  // Auto-cleanup
    
    // Sequential structured work - automatically inherits parent's cancellation
    let kit = try await WhisperKit(model: model.id)
    
    // All work is awaited directly in function scope
    let isValid = try await validateModelIntegrity(model.id)
    guard isValid else { throw ... }
}
```

**Benefits**:
- **Zero detached tasks** → Everything inherits parent task context
- `defer` handles cleanup automatically (no manual tracking needed)
- Cancellation propagates naturally from caller to this function
- Simpler mental model → Linear async/await flow
- Swift 6 MainActor-safe → No Sendable issues with structured task inheritance
- **Pure structured concurrency** → No Task.init anywhere

## Alternative Considered
Using `Timer` (GCD-based) would violate Requirement 15.3 ("no GCD").

## AsyncStream: `makeStream` vs Closure-Based Init

### Prefer `AsyncStream.makeStream(of:)` — Especially for Actors

The project standardizes on `AsyncStream.makeStream(of:)` over the closure-based `AsyncStream { continuation in }` init.

### Why the Closure-Based Init Is Dangerous for Actors

The closure passed to `AsyncStream.init` is **nonisolated**. When an actor captures `self` in that closure (even implicitly), it creates a path where the continuation can be accessed outside the actor's isolation domain. During teardown (e.g., `stopCapture()`), this causes:

```
Incorrect actor executor assumption; expected 'wispr.AudioEngine' executor
```

The crash happens because:
1. Audio tap callback fires → `Task {}` → schedules work on actor
2. `stopCapture()` runs on actor → sets `isCapturing = false`, calls `continuation.finish()`
3. The `onTermination` handler (if present) fires from a **different executor**
4. `onTermination` tries to access actor-isolated state → **EXC_BAD_ACCESS**

### The Fix: `makeStream`

```swift
// ✅ CORRECT: makeStream returns continuation as a separate value
let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
self.levelContinuation = continuation  // Store on actor

// ❌ WRONG for actors: closure captures self in nonisolated context
AsyncStream<Float> { continuation in
    self.levelContinuation = continuation  // Nonisolated closure!
}
```

### Explicit Continuation Cleanup

With `makeStream`, the actor owns the continuation and cleans it up explicitly:

```swift
func stopCapture() async -> Data {
    isCapturing = false           // 1. Reject new callbacks
    levelContinuation?.finish()   // 2. End the stream
    levelContinuation = nil       // 3. Release the continuation
    engine.stop()                 // 4. Stop the engine
    engine.inputNode.removeTap(onBus: 0)  // 5. Remove the tap
    // ...
}
```

Key ordering: set `isCapturing = false` **before** finishing the continuation, so any in-flight `Task {}` from the audio tap sees the flag and exits early in `processAudioBufferData`.

### No `onTermination` Handler

Do NOT use `continuation.onTermination` with actors. It creates a detached callback that runs outside actor isolation. Instead, handle all cleanup explicitly in `stopCapture()` and `cancelCapture()`.

## Testing
All test files use `withTaskGroup` for consuming AsyncStreams and managing concurrent test operations, demonstrating proper structured concurrency patterns.

## Conclusion
The Task {} usage in AsyncStream closures is **idiomatic Swift concurrency** and represents **structured concurrency**. This pattern is commonly used for:
- Polling APIs
- Network heartbeats  
- Reactive streams
- Bridging sync callbacks to async code

**Avoid** using `Task.init` to create detached tasks - always await work directly in the function's scope for proper structured concurrency.

## TextInsertionService: @MainActor Class (Not Actor)

TextInsertionService was initially implemented as an `actor` but had to be changed to a `@MainActor final class` because:

1. **NSPasteboard.general is @MainActor-isolated** - accessing it from an actor context causes EXC_BAD_ACCESS crashes
2. **CGEvent APIs require main thread** - keyboard simulation must run on the main thread
3. **AXUIElement APIs are main-thread-bound** - Accessibility APIs expect main thread execution

### Key Implementation Details:
- Changed from `actor TextInsertionService` to `@MainActor final class TextInsertionService`
- Added type safety checks for Core Foundation objects using `CFGetTypeID()` before force-casting
- Properly handle AXUIElement, AXValue type validation to prevent crashes
- All methods remain synchronous or async as appropriate, but now run on MainActor

### Test Limitations:
TextInsertionService tests crash in unit test environment because:
- NSPasteboard requires proper entitlements
- Accessibility APIs require accessibility permissions
- CGEvent posting requires specific test environment setup

Tests are included for documentation but will fail in standard unit test runs. Integration testing or UI testing would be more appropriate for this service.
