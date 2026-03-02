# Wispr — Mac App Store Publishing Checklist

## 1. Apple Developer Program
- [X] Active Apple Developer Program membership ($99/year)
- [X] App Store Connect account set up
- [X] Certificates, Identifiers & Profiles configured in the developer portal

## 2. Xcode Project Configuration
- [X] Bundle Identifier is unique and registered — `com.stormacq.app.macos.wispr`
- [X] Version number set — `MARKETING_VERSION = 1.0`
- [X] Build number set — `CURRENT_PROJECT_VERSION = 1`
- [X] Deployment target set — `MACOSX_DEPLOYMENT_TARGET = 26.2`
- [X] App Category selected — `public.app-category.utilities`
- [ ] Signing configured with "Apple Distribution" certificate *(manual — switch from dev to distribution before archive)*
- [ ] Provisioning profile created for Mac App Store distribution *(manual — App Store Connect)*
- [X] App Sandbox entitlement enabled (`ENABLE_APP_SANDBOX = YES`)

## 3. App Sandbox & Entitlements Audit
- [X] `com.apple.security.app-sandbox` = `YES`
- [X] `com.apple.security.device.audio-input` = `YES` (microphone access)
- [X] `com.apple.security.network.client` = `YES` (WhisperKit model downloads)
- [X] File access entitlements — models stored in `Application Support/wispr/` (sandbox container)
- [X] Removed `getpwuid` usage in `WhisperService.modelDownloadBase` — now uses `FileManager` Application Support
- [X] `com.apple.security.temporary-exception.*` removed
- [X] Accessibility APIs — `AXUIElement` used for text insertion, `AXIsProcessTrusted()` for permission check. **No entitlement needed** — accessibility is a runtime permission granted by the user in System Settings, not an entitlement.
- [X] Global hotkey — uses `RegisterEventHotKey` (Carbon), **not** CGEvent taps. Works in App Sandbox without special entitlements. No `temporary-exception.apple-events` needed.

## 4. Privacy & Permissions
- [X] `NSMicrophoneUsageDescription` in Info.plist — "Wispr uses your microphone to convert speech to text entirely on your Mac. For example, hold the keyboard shortcut, dictate a message or email, and Wispr transcribes your words and inserts the text into any app. Audio is processed locally and is never sent to a server."
- [X] Apple Events — **not used**. No `NSAppleEventsUsageDescription` needed. *(Original checklist item was misleading — the app uses Accessibility APIs for text insertion, not Apple Events. These are separate permission domains.)*
- [ ] Privacy Nutrition Label filled out in App Store Connect:
  - [ ] Confirm **no data collected** (all processing is local)
  - [ ] Confirm no analytics, no tracking, no third-party SDKs that collect data
- [ ] Privacy Policy URL — required even if you collect nothing; host a simple page stating no data is collected

## 5. App Review Preparation
- [ ] **Demo instructions** — prepare App Review notes explaining:
  - How to grant microphone permission
  - How to grant accessibility permission (System Settings)
  - How to download a model (reviewer needs internet)
  - How to test dictation (hold ⌥Space → speak → release)
- [X] Global hotkey works under sandbox — `RegisterEventHotKey` (Carbon) needs no special entitlements
- [X] Clean install works — models stored in sandbox container `Application Support/wispr/`
- [X] Microphone denied handled gracefully — denied state shows explanation + "Open System Settings" button
- [X] No internet handled gracefully — download errors surface with retry button in UI
- [ ] Test with a fresh user account on a clean macOS install *(manual)*
- [X] No private API usage — audit confirmed: only public frameworks (`ApplicationServices`, `AVFAudio`, `Carbon`, `CoreAudio`, `CoreGraphics`, `AppKit`). No `dlopen`, `dlsym`, `objc_msgSend`, `NSClassFromString`, or `performSelector`.
- [X] No hardcoded file paths outside sandbox — audit confirmed: no `/Users/`, `/tmp/`, `NSHomeDirectory()`, or `getpwuid` in Swift source.

## 6. Code Signing & Notarization
- [ ] Archive the app with "Apple Distribution" signing identity *(manual)*
- [X] Hardened Runtime enabled (`ENABLE_HARDENED_RUNTIME = YES` in both Debug and Release)
- [ ] All embedded frameworks and dylibs are signed *(verify after archive)*
- [ ] WhisperKit / CoreML model files are included in the bundle signature *(verify after archive — note: models are downloaded at runtime, not bundled)*
- [ ] Validate the archive in Xcode Organizer before uploading *(manual)*

> **Note on item 4**: WhisperKit models are **downloaded at runtime** by the user, not bundled in the app. They live in the sandbox container. There are no model files in the bundle to sign. This item is misleading — removed from blockers.

## 7. App Store Connect Metadata
- [ ] App Name: "Wispr" (check availability — names are globally unique)
- [ ] Subtitle (30 chars max, e.g., "Local Voice to Text")
- [ ] Description (up to 4000 chars) — highlight privacy, local processing, no cloud
- [ ] Keywords (100 chars total, comma-separated)
- [ ] Primary Language
- [X] Category — `public.app-category.utilities` (set in Xcode project)
- [ ] Content Rating questionnaire completed
- [ ] Copyright string — currently empty in `INFOPLIST_KEY_NSHumanReadableCopyright`. Set before submission.

## 8. Screenshots & App Preview
- [ ] At least one screenshot required
- [ ] Recommended: screenshots showing onboarding, recording overlay, menu bar, settings
- [ ] Screenshot sizes for Mac: 1280×800 or 1440×900 (16:10 ratio)
- [ ] Optional: App Preview video (15–30 seconds, showing dictation workflow)

> **Removed**: "If app supports multiple languages, localized screenshots for each" — Wispr's UI is English-only. Multi-language support is for *transcription input*, not UI localization. No localized screenshots needed.

## 9. App Icon
- [X] macOS app icon set present with all standard sizes (16–512 @1x/@2x)
- [ ] Verify 1024×1024 variant is included for App Store submission *(512@2x = 1024px but may need explicit 1024@1x entry)*
- [X] Icon follows macOS rounded-rect shape (do not mask it yourself — macOS applies the mask)
- [X] Icon is distinct and recognizable at 16×16

## 10. Pricing & Availability
- [ ] Decide pricing model: Free / Paid / Freemium
- [ ] Select territories for availability
- [ ] If paid: set up bank account and tax forms in App Store Connect
- [ ] If using in-app purchases: configure and submit for review

## 11. Legal
- [ ] Privacy Policy URL (required)
- [ ] License Agreement (can use Apple's standard EULA or provide custom)
- [X] WhisperKit license compatible with App Store distribution (MIT)
- [X] All dependencies' licenses permit App Store distribution — WhisperKit (MIT), Apple packages (Apache 2.0), Hugging Face packages (Apache 2.0), yyjson (MIT)
- [ ] Check trademark availability for "Wispr" name

## 12. Testing Before Submission
- [X] Test on minimum supported macOS version (26.2)
- [X] Test on latest macOS version
- [X] Apple Silicon only (`ARCHS = arm64`) — no Intel/Universal support
- [ ] Test with VoiceOver enabled (accessibility labels and hints are implemented)
- [ ] Test with Increase Contrast, Reduce Motion, Reduce Transparency
- [ ] Test with the app sandboxed (Archive build, not debug)
- [X] Test full flow: launch → onboarding → download model → grant permissions → record → transcribe → paste
- [X] Test launch at login via `SMAppService` — fixed Guideline 2.4.5(iii) rejection: no longer auto-registers on startup
- [X] Test with microphone permission denied
- [ ] Test with no internet (model download should fail gracefully)
- [ ] TestFlight for Mac — distribute a beta build to external testers

## 13. ⚠️ Critical Blockers for This App

| Issue | Status |
|-------|--------|
| ~~`~/.wispr` model storage via `getpwuid`~~ | **Fixed** — models now stored in Application Support (sandbox container) |
| Global hotkey via `Carbon` APIs | **Verified** — `RegisterEventHotKey` works in sandbox, no special entitlements needed |
| `ServiceManagement` (`SMAppService`) | **Verified** — uses modern `SMAppService.mainApp` API (not deprecated `SMLoginItemSetEnabled`), sandbox-compatible |
| ~~Auto-launch without user consent (Guideline 2.4.5(iii))~~ | **Fixed** — `updateLaunchAtLogin()` is now guarded by `isLoading` in `didSet`, so `SMAppService.register()` is never called during `load()`. `launchAtLogin` reads from `SMAppService.mainApp.status` (system source of truth) instead of UserDefaults. |
| ~~WhisperKit model download to arbitrary path~~ | **Fixed** — downloads to `Application Support/wispr/` inside sandbox container |

## 14. Post-Submission
- [ ] Monitor App Store Connect for review status updates
- [ ] Respond promptly to any reviewer questions or rejection notes
- [ ] Prepare 1.0.1 with any fixes from review feedback
- [ ] Set up crash reporting (MetricKit or similar) for production monitoring
- [ ] Plan for macOS version compatibility updates (new macOS releases yearly)
