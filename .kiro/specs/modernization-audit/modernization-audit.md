# Wisp Codebase Modernization Audit

> Generated: February 2026
> Swift 6.0 · Strict Concurrency: complete · Default Actor Isolation: MainActor

---

## Project Build Settings

- `SWIFT_VERSION = 6.0`
- `SWIFT_STRICT_CONCURRENCY = complete`
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- `SWIFT_APPROACHABLE_CONCURRENCY = YES`
- `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY = YES`

---

## 1. AppKit Usage That MUST Stay (No SwiftUI Replacement)

| File | AppKit API | Reason |
|---|---|---|
| `wisprApp.swift` | `NSApplicationDelegateAdaptor`, `NSWindow`, `NSHostingController` | SwiftUI `Window` scenes don't reliably open in `.accessory` (menu-bar-only) apps. No SwiftUI API for `setActivationPolicy(.accessory)`. |
| `MenuBarController.swift` | `NSStatusBar`, `NSStatusItem`, `NSMenu`, `NSMenuItem` | No SwiftUI equivalent for `NSStatusItem`. `MenuBarExtra` doesn't support dynamic icon changes, submenus, or target-action wiring. |
| `RecordingOverlayPanel.swift` | `NSPanel` with `.nonactivatingPanel`, `.borderless` | SwiftUI has no way to create a non-activating floating panel that doesn't steal focus. |
| `TextInsertionService.swift` | `AXUIElement*`, `CGEvent`, `NSPasteboard` | Low-level system APIs with no higher-level replacement. Required for text insertion at cursor in arbitrary apps. |
| `HotkeyMonitor.swift` | Carbon Event APIs (`RegisterEventHotKey`, `InstallEventHandler`) | Carbon is the only stable macOS API for system-wide global hotkey registration. Apple provides no alternative. |
| `PermissionManager.swift` | `AXIsProcessTrusted()`, `NSWorkspace.shared.open()` | No SwiftUI equivalent for checking accessibility trust or opening System Settings to a specific pane. |
| `UIThemeEngine.swift` | `NSApp.effectiveAppearance`, `NSWorkspace.shared.accessibilityDisplay*` | SwiftUI `@Environment(\.colorScheme)` covers light/dark but not accessibility display options. |
| `AudioEngine.swift` | `AVAudioEngine`, Core Audio C APIs | No higher-level replacement for real-time audio capture with sample-rate conversion. |
| `StateManager.swift` | `NSAccessibility.post()`, `NSPasteboard` | No SwiftUI equivalent for posting arbitrary VoiceOver announcements from non-view code. |
| `MenuBarController.swift` | `MenuBarActionHandler: NSObject` | `NSMenuItem` target-action requires `@objc` methods. Unavoidable AppKit bridge. |

---

## 2. Actionable Modernization Items

### 2a. Deprecated API — `NSApp.activate(ignoringOtherApps:)` ⚠️

**Files:** `wisprApp.swift`, `MenuBarController.swift`
**Current:** `NSApp.activate(ignoringOtherApps: true)`
**Fix:** Replace with `NSApp.activate()` (deprecated in macOS 14).
**Effort:** Trivial.

### 2b. Deprecated API — `Task.sleep(nanoseconds:)`

**File:** `WhisperService.swift` → `reloadModelWithRetry()`
**Current:**
```swift
let delay = UInt64(pow(2.0, Double(attempt))) * 1_000_000_000
try await Task.sleep(nanoseconds: delay)
```
**Fix:**
```swift
try await Task.sleep(for: .seconds(pow(2.0, Double(attempt))))
```
**Effort:** Trivial. One occurrence. Rest of codebase already uses `Task.sleep(for:)`.

### 2c. Polling Timer → KVO / Notification Observation

**File:** `UIThemeEngine.swift`
**Current:** Polls `NSWorkspace` accessibility settings and `NSApp.effectiveAppearance` every 1 second via `Task.sleep`.
**Fix:**
- Accessibility: Use `NSWorkspace.didChangeAccessibilityDisplayOptionsNotification` via `NotificationCenter.notifications(named:)` async sequence.
- Appearance: Use KVO on `NSApp.observe(\.effectiveAppearance)` or wrap in `AsyncStream`.
**Effort:** Low. Eliminates unnecessary polling.

### 2d. `wispLog()` → `os.Logger`

**File:** `Utilities/Logger.swift`
**Current:** Custom `print()`-based logging gated by `#if DEBUG`.
**Fix:** Use `os.Logger` with subsystem/category for structured logging. Enables filtering in Console.app and works in release builds with appropriate log levels.
**Effort:** Low-medium (touch many call sites, but mechanical).

---

## 3. Swift 6 Concurrency Notes

### 3a. `nonisolated(unsafe)` Usage (Acceptable, Track for Removal)

| File | Property | Safety Invariant |
|---|---|---|
| `HotkeyMonitor.swift` | `hotkeyRef`, `eventHandlerRef`, `wakeObserver` | Needed for `deinit` cleanup. Opaque pointers only accessed from main thread. |
| `WhisperService.swift` | `whisperKit: WhisperKit?` | WhisperKit is not `Sendable`. Only accessed within actor isolation. **Track for removal when WhisperKit adds `Sendable`.** |
| `AudioEngine.swift` | `hasLoggedFirstBuffer` (tap closure) | Debug-only mutable flag in `@Sendable` closure. Low risk. Could use `OSAllocatedUnfairLock<Bool>`. |
| `AudioEngine.swift` | `inputBuffer` (converter closure) | `AVAudioPCMBuffer` non-Sendable, used synchronously in same callback scope. |

### 3b. Unstructured `Task {}` — Fire-and-Forget

| File | Location | Note |
|---|---|---|
| `wisprApp.swift` | `bootstrap()` — permission monitoring | Task never cancelled. Should store and cancel in `applicationWillTerminate`. |
| `wisprApp.swift` | `bootstrap()` — model loading | Best-effort load, errors logged. Acceptable. |
| `wisprApp.swift` | `completeOnboarding()` | Same pattern. Acceptable. |

### 3c. Observation Pattern

`withObservationTracking` loops in `wisprApp.swift`, `MenuBarController.swift`, `StateManager.swift` are the correct idiomatic pattern for observing `@Observable` outside SwiftUI views. Verbose but no simpler API exists yet.

### 3d. `RecordingSession.audioData` — Unnecessary `var`

**File:** `Models/RecordingSession.swift`
**Current:** `var audioData: Data?`
**Note:** Never mutated after creation. Could be `let` for clarity.

---

## 4. APIs That Are Already Modern (No Action Needed)

| API | File | Note |
|---|---|---|
| `SMAppService.mainApp` | `SettingsStore.swift` | Already the modern replacement for `LSSharedFileList`. |
| `@Observable` (Observation framework) | All `@Observable` classes | Modern replacement for `ObservableObject` / `@Published`. |
| `AsyncStream.makeStream()` | `AudioEngine.swift` | Modern factory method, avoids closure-based init. |
| `AVAudioApplication.requestRecordPermission()` | `PermissionManager.swift` | Modern async API. |
| `UserDefaults` | `SettingsStore.swift` | Standard. `@AppStorage` doesn't support custom `Codable` types. |
| `ByteCountFormatter` | `ModelDownloadProgressView.swift` | Still the standard approach. |
| `ServiceManagement` | `SettingsStore.swift` | Modern login item API. |

---

## 5. Refactor Priority

1. **Quick wins (do first):** Items 2a and 2b — fix two deprecated API calls.
2. **Low effort, good payoff:** Item 2c — replace polling with KVO/notifications in `UIThemeEngine`.
3. **Nice to have:** Item 2d — migrate to `os.Logger`.
4. **Track externally:** Item 3a — `nonisolated(unsafe)` on `WhisperService.whisperKit` pending WhisperKit `Sendable` support.
5. **Minor cleanup:** Item 3d — `RecordingSession.audioData` `var` → `let`.
6. **Blocked (no SwiftUI API):** Item 2e — `NSAnimationContext` in `RecordingOverlayPanel` tied to `NSPanel` usage. Migrate when SwiftUI gains a floating panel primitive.
7. **Blocked (narrower gap on macOS 26):** Item 2f — `NSPanel` can't be fully replaced yet. macOS 26 added `.windowLevel(.floating)`, `.windowStyle(.plain)`, and `.allowsWindowActivationEvents(false)`, but still lacks a non-activating window scene that doesn't steal focus on show. Monitor macOS 27.

**Critical blocker remains:** SwiftUI `Window`/`openWindow(id:)` **always activates the app** when shown. `.allowsWindowActivationEvents(false)` only prevents *gestures within the window* from activating — the window appearance itself still brings your app forward, stealing focus from whatever the user was using (Safari, Notes, etc.). This breaks the dictation UX.

### 2e. `NSAnimationContext` → SwiftUI `.withAnimation` / `.transition`

**File:** `RecordingOverlayPanel.swift` — `show()` and `dismiss()`
**Current:** Two `NSAnimationContext.runAnimationGroup` calls that fade the `NSPanel` alpha in/out using `panel.animator().alphaValue`. Already respects Reduce Motion via `themeEngine.reduceMotion`.

```swift
// show()
NSAnimationContext.runAnimationGroup { context in
    context.duration = duration
    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
    panel.animator().alphaValue = 1.0
}

// dismiss()
NSAnimationContext.runAnimationGroup({ context in
    context.duration = duration
    context.timingFunction = CAMediaTimingFunction(name: .easeIn)
    panel.animator().alphaValue = 0.0
}, completionHandler: { ... })
```

**SwiftUI replacement path:**
If the overlay were a pure SwiftUI view (not hosted in an `NSPanel`), the animations would be:
```swift
// In the SwiftUI view:
.opacity(isVisible ? 1 : 0)
.animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: isVisible)
.transition(.opacity)
```
With the dismiss completion handler replaced by `withAnimation(.easeIn(duration: 0.2)) { isVisible = false }` and an `.onDisappear` or `.task` to handle cleanup.

**However:** As noted in Section 1, `RecordingOverlayPanel` uses `NSPanel` with `.nonactivatingPanel` and `.borderless` because SwiftUI has no API for creating a non-activating floating panel that doesn't steal focus. The `NSAnimationContext` usage is therefore tied to the `NSPanel` requirement and cannot be replaced with SwiftUI animations unless Apple provides a SwiftUI-native floating panel API.

**Recommendation:** Keep as-is. The `NSAnimationContext` usage is correct and idiomatic for animating `NSWindow`/`NSPanel` properties. If a future macOS release adds a SwiftUI floating panel primitive, both the panel and its animations could migrate together.

**Effort:** N/A (blocked on missing SwiftUI API).

### 2f. `NSPanel` → SwiftUI Window / Overlay

**File:** `RecordingOverlayPanel.swift`
**Current:** A hand-managed `NSPanel` with `[.borderless, .nonactivatingPanel]` style mask, configured as a floating window (`level: .floating`, `hidesOnDeactivate: false`, `collectionBehavior: [.canJoinAllSpaces, .fullScreenAuxiliary]`). Hosts a SwiftUI `RecordingOverlayView` via `NSHostingView`.

**Why it exists:** The overlay must:
1. Float above all windows without stealing keyboard focus (`.nonactivatingPanel`)
2. Remain visible when the app is not frontmost (`hidesOnDeactivate: false`)
3. Appear on all Spaces/desktops (`.canJoinAllSpaces`)
4. Work alongside fullscreen apps (`.fullScreenAuxiliary`)
5. Be borderless and transparent (`backgroundColor: .clear`, `.borderless`)

**SwiftUI alternatives considered:**

| SwiftUI API | Viable? | Why not |
|---|---|---|
| `Window` scene | No | Always activating. No `.nonactivatingPanel` equivalent. Cannot prevent focus steal. |
| `MenuBarExtra` with detached content | No | Anchored to menu bar, not freely positionable. |
| `.overlay()` / `ZStack` on existing view | No | Scoped to the app's own window, not a system-wide floating panel. |
| `WindowGroup` + `windowStyle(.plain)` | No | Still activating. No way to set `NSWindow.level` or collection behavior. |
| `.popover()` | No | Anchored, dismisses on outside click, not a persistent overlay. |

**Conclusion:** As of macOS 26 (Tahoe), SwiftUI has added several relevant APIs that get closer but still don't fully cover the `NSPanel` use case:

| SwiftUI API (macOS 26) | What it does | Covers our need? |
|---|---|---|
| `.windowLevel(.floating)` | Sets window to floating level | ✅ Yes — replaces `panel.level = .floating` |
| `.windowStyle(.plain)` | Removes window chrome (title bar, etc.) | ✅ Yes — replaces `.borderless` style mask |
| `.allowsWindowActivationEvents(false)` | Prevents gestures from activating the window | ⚠️ Partial — controls gesture activation, but doesn't replicate `.nonactivatingPanel` behavior (the window itself still activates when shown) |
| `.windowDismissBehavior(.disabled)` | Prevents close button | ✅ Yes |
| `.windowResizeBehavior(.disabled)` | Prevents resize | ✅ Yes |
| `.defaultWindowPlacement(...)` | Custom positioning | ✅ Yes — replaces `positionPanel()` |
| `WindowPlacement.Position.utilityPanel` | Utility panel positioning | ⚠️ Partial — visionOS-oriented |

The critical missing piece remains: there is no SwiftUI equivalent for `NSPanel`'s `.nonactivatingPanel` style mask behavior. A SwiftUI `Window` scene still activates the app when shown via `openWindow`, which would steal focus from whatever app the user is dictating into. The `allowsWindowActivationEvents(false)` modifier only controls whether gestures within the window trigger activation — it doesn't prevent the window itself from activating the app when it appears.

Additionally, there's no SwiftUI equivalent for:
- `hidesOnDeactivate = false` (keeping the window visible when the app isn't frontmost)
- `.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]`
- `orderFrontRegardless()` (showing without activation)

**Recommendation:** Keep `NSPanel` for now. The gap is narrower on macOS 26 than before, but the non-activating behavior is still the blocker. Monitor macOS 27 / WWDC 2026 for a potential `WindowActivationPolicy` or similar API.

**Effort:** N/A (blocked on missing non-activating window API).

---

## 6. DispatchQueue / GCD Audit

### Status: ✅ Resolved

**Single occurrence found and removed:**

| File | Line | Old Code | Resolution |
|---|---|---|---|
| `wisprApp.swift` | ~291 | `DispatchQueue.main.async { self.updateOverlayVisibility(...) }` inside `withObservationTracking` `onChange` | Removed. The `onChange` closure now just resumes the continuation; the next `while` loop iteration calls `updateOverlayVisibility` on `@MainActor`, making the GCD dispatch redundant. |

**No other GCD primitives found:** No `DispatchSemaphore`, `DispatchGroup`, `DispatchWorkItem`, or `DispatchQueue.global()` usage anywhere in the codebase. The project is fully on Swift Concurrency.
