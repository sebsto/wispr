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
