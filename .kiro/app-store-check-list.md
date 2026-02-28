# Wisp — Mac App Store Publishing Checklist

## 1. Apple Developer Program
- [X] Active Apple Developer Program membership ($99/year)
- [X] App Store Connect account set up
- [X] Certificates, Identifiers & Profiles configured in the developer portal

## 2. Xcode Project Configuration
- [ ] Bundle Identifier is unique and registered (e.g., `com.yourname.wispr`)
- [ ] Version number set (e.g., `1.0.0`) — `CFBundleShortVersionString`
- [ ] Build number set (e.g., `1`) — `CFBundleVersion`
- [ ] Deployment target set to minimum supported macOS version
- [ ] App Category selected (likely **Utilities** or **Productivity**)
- [ ] Signing configured with "Apple Distribution" certificate
- [ ] Provisioning profile created for Mac App Store distribution
- [ ] App Sandbox entitlement enabled (required for Mac App Store)

## 3. App Sandbox & Entitlements Audit
- [X] `com.apple.security.app-sandbox` = `YES`
- [X] `com.apple.security.device.audio-input` = `YES` (microphone access)
- [X] `com.apple.security.network.client` = `YES` (WhisperKit model downloads)
- [X] File access entitlements — models stored in `Application Support/wispr/` (sandbox container)
- [X] Removed `getpwuid` usage in `WhisperService.modelDownloadBase` — now uses `FileManager` Application Support
- [X] `com.apple.security.temporary-exception.*` removed
- [ ] Accessibility API usage (if any) requires `com.apple.security.accessibility`
- [ ] Global hotkey registration (`Carbon` hotkeys) — verify it works under sandbox; may need `com.apple.security.temporary-exception.apple-events` or switch to `CGEvent` tap with Accessibility permissions

## 4. Privacy & Permissions
- [ ] `NSMicrophoneUsageDescription` in Info.plist — clear, user-facing string explaining why the mic is needed (e.g., "Wisp uses your microphone to transcribe speech to text locally on your device.")
- [ ] If using Accessibility APIs for global hotkey: `NSAppleEventsUsageDescription` or prompt for Accessibility permission
- [ ] Privacy Nutrition Label filled out in App Store Connect:
  - [ ] Confirm **no data collected** (all processing is local)
  - [ ] Confirm no analytics, no tracking, no third-party SDKs that collect data
- [ ] Privacy Policy URL — required even if you collect nothing; host a simple page stating no data is collected

## 5. App Review Preparation
- [ ] **Demo instructions** — prepare App Review notes explaining:
  - How to grant microphone permission
  - How to download a model (reviewer needs internet)
  - How to test dictation (hold hotkey → speak → release)
  - How to configure the global hotkey
- [ ] Global hotkey may require Accessibility permission — document this for reviewers
- [ ] Ensure the app works on a clean install with no pre-existing model directory
- [ ] Ensure the app handles "microphone denied" gracefully (not just a crash or hang)
- [ ] Ensure the app handles "no internet" gracefully during model download
- [ ] Test with a fresh user account on a clean macOS install
- [ ] No private API usage — audit all `Carbon`, `CoreAudio`, and low-level calls
- [ ] No hardcoded file paths outside the sandbox container

## 6. Code Signing & Notarization
- [ ] Archive the app with "Apple Distribution" signing identity
- [ ] Hardened Runtime enabled
- [ ] All embedded frameworks and dylibs are signed
- [ ] WhisperKit / CoreML model files are included in the bundle signature
- [ ] Validate the archive in Xcode Organizer before uploading

## 7. App Store Connect Metadata
- [ ] App Name: "Wisp" (check availability — names are globally unique)
- [ ] Subtitle (30 chars max, e.g., "Local Voice to Text")
- [ ] Description (up to 4000 chars) — highlight privacy, local processing, no cloud
- [ ] Keywords (100 chars total, comma-separated)
- [ ] Primary Language
- [ ] Category: Utilities or Productivity
- [ ] Content Rating questionnaire completed
- [ ] Copyright string (e.g., "© 2025 Your Name")

## 8. Screenshots & App Preview
- [ ] At least one screenshot required
- [ ] Recommended: screenshots showing settings, recording overlay, menu bar states
- [ ] Screenshot sizes for Mac: 1280×800 or 1440×900 (16:10 ratio)
- [ ] Optional: App Preview video (15–30 seconds, showing dictation workflow)
- [ ] If app supports multiple languages, localized screenshots for each

## 9. App Icon
- [ ] macOS app icon at 1024×1024 (for App Store) and all required sizes
- [ ] Icon follows macOS rounded-rect shape (do not mask it yourself — macOS applies the mask)
- [ ] Icon is distinct and recognizable at 16×16

## 10. Pricing & Availability
- [ ] Decide pricing model: Free / Paid / Freemium
- [ ] Select territories for availability
- [ ] If paid: set up bank account and tax forms in App Store Connect
- [ ] If using in-app purchases: configure and submit for review

## 11. Legal
- [ ] Privacy Policy URL (required)
- [ ] License Agreement (can use Apple's standard EULA or provide custom)
- [ ] Ensure WhisperKit license is compatible with App Store distribution (MIT — ✅)
- [ ] Ensure any other dependencies' licenses permit App Store distribution
- [ ] Check trademark availability for "Wisp" / "Wispr" name

## 12. Testing Before Submission
- [ ] Test on minimum supported macOS version
- [ ] Test on latest macOS version
- [ ] Test on both Apple Silicon and Intel (if supporting Universal)
- [ ] Test with VoiceOver enabled (your accessibility labels and hints)
- [ ] Test with Increase Contrast, Reduce Motion, Reduce Transparency
- [ ] Test with the app sandboxed (Archive build, not debug)
- [ ] Test full flow: launch → download model → grant mic permission → record → transcribe → paste
- [ ] Test launch at login via `SMAppService`
- [ ] Test with microphone permission denied
- [ ] Test with no internet (model download should fail gracefully)
- [ ] TestFlight for Mac — distribute a beta build to external testers

## 13. ⚠️ Critical Blockers for This App

These items from the codebase will **likely cause App Store rejection** if not addressed:

| Issue | Why It's a Problem |
|-------|-------------------|
| ~~`~/.wispr` model storage via `getpwuid`~~ | **Fixed** — models now stored in Application Support (sandbox container) |
| Global hotkey via `Carbon` APIs | May require Accessibility permission; must work under sandbox |
| `ServiceManagement` (`SMAppService`) | Should work, but test under sandbox to confirm |
| ~~WhisperKit model download to arbitrary path~~ | **Fixed** — downloads to `Application Support/wispr/` inside sandbox container |

## 14. Post-Submission
- [ ] Monitor App Store Connect for review status updates
- [ ] Respond promptly to any reviewer questions or rejection notes
- [ ] Prepare 1.0.1 with any fixes from review feedback
- [ ] Set up crash reporting (MetricKit or similar) for production monitoring
- [ ] Plan for macOS version compatibility updates (new macOS releases yearly)
