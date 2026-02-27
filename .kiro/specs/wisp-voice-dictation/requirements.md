# Requirements Document

## Introduction

Wisp is a privacy-first macOS menu bar application for voice dictation. It captures speech via the system microphone, transcribes it on-device using a Whisper model (WhisperKit), and inserts the resulting text at the user's cursor position in any application. All processing happens locally — no audio data leaves the machine. The app is activated via a configurable global hotkey (default ⌥Space) and lives entirely in the macOS menu bar.

## Glossary

- **Wisp**: The macOS menu bar voice dictation application described in this document.
- **Audio_Engine**: The component responsible for capturing microphone audio using AVAudioEngine.
- **Whisper_Service**: The component responsible for on-device speech-to-text transcription using WhisperKit.
- **Text_Insertion_Service**: The component responsible for inserting transcribed text at the active cursor position via macOS Accessibility APIs or clipboard fallback.
- **Hotkey_Monitor**: The component responsible for registering and detecting global keyboard shortcuts using Carbon Event APIs.
- **Permission_Manager**: The component responsible for requesting and monitoring macOS permissions (microphone, accessibility).
- **Menu_Bar_Controller**: The component responsible for the NSStatusItem menu bar presence, status icon, and dropdown menu.
- **Recording_Session**: A single cycle of audio capture from hotkey press to hotkey release.
- **Whisper_Model**: A local speech recognition model file (e.g., tiny, base, small, medium, large) used by the Whisper_Service.
- **State_Manager**: The central coordinator that manages application state transitions (idle, recording, processing, error).
- **Settings_Store**: The persistent storage for user preferences using UserDefaults/AppStorage.
- **Recording_Overlay**: The floating UI window displayed during an active Recording_Session showing audio feedback.
- **Onboarding_Flow**: The multi-step first-launch setup wizard that guides the user through permissions, model download, and an interactive test dictation before normal use.
- **UI_Theme_Engine**: The component responsible for managing visual appearance, system appearance adaptation, Liquid Glass materials, and animation coordination across all Wisp views.
- **Liquid_Glass**: The translucent, glass-like design language introduced in macOS 26 (Tahoe) that uses layered translucency, vibrancy, and depth to create a fluid, premium visual aesthetic.

## Requirements

### Requirement 1: Global Hotkey Activation

**User Story:** As a user, I want to start and stop voice recording with a global hotkey so that I can quickly dictate from any application without switching context.

#### Acceptance Criteria

1. WHEN the user presses the configured global hotkey, THE Hotkey_Monitor SHALL signal the State_Manager to begin a new Recording_Session.
2. WHEN the user releases or re-presses the configured global hotkey during an active Recording_Session, THE Hotkey_Monitor SHALL signal the State_Manager to end the Recording_Session.
3. THE Settings_Store SHALL persist a default hotkey of ⌥Space (Option + Space).
4. WHEN the user assigns a new hotkey combination in settings, THE Hotkey_Monitor SHALL register the new combination and unregister the previous one.
5. IF the configured hotkey conflicts with a system-reserved shortcut, THEN THE Hotkey_Monitor SHALL display a conflict warning and retain the previous hotkey.
6. WHILE the Hotkey_Monitor has no valid hotkey registered, THE Menu_Bar_Controller SHALL display a warning indicator.

### Requirement 2: Audio Recording

**User Story:** As a user, I want Wisp to capture my speech through the microphone so that it can be transcribed into text.

#### Acceptance Criteria

1. WHEN a Recording_Session begins, THE Audio_Engine SHALL start capturing audio from the selected input device.
2. WHEN a Recording_Session ends, THE Audio_Engine SHALL stop capturing and provide the recorded audio data to the Whisper_Service.
3. WHILE a Recording_Session is active, THE Audio_Engine SHALL publish real-time audio level values for the Recording_Overlay.
4. IF the selected audio input device becomes unavailable during a Recording_Session, THEN THE Audio_Engine SHALL fall back to the system default input device and continue recording.
5. IF no audio input device is available, THEN THE Audio_Engine SHALL cancel the Recording_Session and THE State_Manager SHALL transition to the error state with a descriptive message.
6. THE Audio_Engine SHALL capture audio at a sample rate and format compatible with the active Whisper_Model.

### Requirement 3: On-Device Transcription

**User Story:** As a user, I want my speech transcribed using an on-device Whisper model so that my voice data never leaves my computer.

#### Acceptance Criteria

1. WHEN the Audio_Engine provides recorded audio data, THE Whisper_Service SHALL transcribe the audio into text using the active Whisper_Model.
2. THE Whisper_Service SHALL perform all transcription processing locally without transmitting audio data over any network.
3. WHEN transcription completes successfully, THE Whisper_Service SHALL pass the resulting text to the Text_Insertion_Service.
4. IF transcription produces an empty result, THEN THE Whisper_Service SHALL notify the State_Manager, and THE State_Manager SHALL transition to idle without inserting text.
5. IF transcription fails due to a model error, THEN THE Whisper_Service SHALL report the error to the State_Manager, and THE State_Manager SHALL display an error message to the user.
6. WHILE transcription is in progress, THE State_Manager SHALL set the application state to processing.

### Requirement 4: Text Insertion

**User Story:** As a user, I want transcribed text automatically inserted at my cursor position so that I can dictate into any application seamlessly.

#### Acceptance Criteria

1. WHEN the Whisper_Service provides transcribed text, THE Text_Insertion_Service SHALL insert the text at the current cursor position in the frontmost application using macOS Accessibility APIs.
2. IF the frontmost application does not support Accessibility-based text insertion, THEN THE Text_Insertion_Service SHALL fall back to clipboard-based insertion (copy text to pasteboard and simulate ⌘V).
3. WHEN text insertion completes, THE State_Manager SHALL transition to the idle state.
4. IF text insertion fails via both Accessibility and clipboard fallback, THEN THE Text_Insertion_Service SHALL retain the transcribed text on the pasteboard and notify the user that the text is available for manual pasting.
5. THE Text_Insertion_Service SHALL restore the original pasteboard contents after a clipboard-based insertion within 2 seconds.

### Requirement 5: Menu Bar Interface

**User Story:** As a user, I want Wisp to live in my menu bar so that it is always accessible without cluttering my dock or desktop.

#### Acceptance Criteria

1. THE Menu_Bar_Controller SHALL create an NSStatusItem in the macOS menu bar on application launch.
2. THE Menu_Bar_Controller SHALL display a microphone icon that reflects the current application state: idle, recording, or processing.
3. WHEN the user clicks the menu bar icon, THE Menu_Bar_Controller SHALL display a dropdown menu with options: Start/Stop Recording, Settings, and Quit.
4. WHEN the user selects "Start Recording" from the menu, THE Menu_Bar_Controller SHALL signal the State_Manager to begin a new Recording_Session.
5. WHEN the user selects "Quit" from the menu, THE Wisp application SHALL clean up all resources (unregister hotkeys, stop audio engine, release Whisper_Model) and terminate.
6. THE Wisp application SHALL set its activation policy to accessory (LSUIElement) so that it does not appear in the Dock.

### Requirement 6: Permission Management

**User Story:** As a user, I want Wisp to guide me through granting necessary permissions so that all features work correctly on first launch.

#### Acceptance Criteria

1. WHEN Wisp launches for the first time, THE Permission_Manager SHALL check the status of microphone and accessibility permissions.
2. IF microphone permission has not been granted, THEN THE Permission_Manager SHALL request microphone access through the system permission dialog.
3. IF accessibility permission has not been granted, THEN THE Permission_Manager SHALL display instructions guiding the user to System Settings > Privacy & Security > Accessibility.
4. WHILE any required permission is not granted, THE Permission_Manager SHALL prevent Recording_Sessions from starting and display a status message indicating which permission is missing.
5. WHEN a previously denied permission is granted, THE Permission_Manager SHALL detect the change and enable the corresponding functionality.

### Requirement 7: Whisper Model Management

**User Story:** As a user, I want a dedicated model management interface where I can see all available models, their download status, and manage them at any time so that I have full control over which models are on my machine and which one is active.

#### Acceptance Criteria

1. THE Whisper_Service SHALL support loading Whisper_Models of sizes: tiny, base, small, medium, and large.
2. THE Menu_Bar_Controller SHALL provide a Model Management view listing all available Whisper_Models with their name, size on disk, and current status (not downloaded, downloading, downloaded, active).
3. WHEN the user opens the Model Management view, THE Whisper_Service SHALL display the download status of each Whisper_Model (not downloaded, downloading with percentage progress, or downloaded).
4. WHEN the user initiates a download for a Whisper_Model, THE Whisper_Service SHALL download the model and display real-time download progress including percentage and bytes transferred.
5. WHEN a Whisper_Model download completes, THE Whisper_Service SHALL validate the model file integrity before making the model available.
6. WHEN the user selects a different downloaded Whisper_Model as active, THE Whisper_Service SHALL switch to the selected model and THE Settings_Store SHALL persist the selection.
7. WHILE no Recording_Session is active, THE Whisper_Service SHALL allow the user to change the active Whisper_Model at any time from the Model Management view.
8. WHEN the user requests deletion of a downloaded Whisper_Model, THE Whisper_Service SHALL remove the model files from disk and update the model status to not downloaded.
9. IF the user requests deletion of the currently active Whisper_Model, THEN THE Whisper_Service SHALL switch to the next smallest downloaded model before deleting the requested model.
10. IF the user deletes the only downloaded Whisper_Model, THEN THE Whisper_Service SHALL set the application state to require a model download and prompt the user to download a model.
11. THE Settings_Store SHALL persist the user's selected Whisper_Model across application restarts.
12. IF the active Whisper_Model fails to load, THEN THE Whisper_Service SHALL attempt to fall back to the smallest available downloaded model.
13. THE Whisper_Service SHALL store all downloaded Whisper_Model files under `~/.wispr/` so that models reside in a fixed, user-visible location independent of App Sandbox or HubApi defaults.

### Requirement 8: Audio Device Selection

**User Story:** As a user, I want to select my preferred microphone so that I get the best audio quality for transcription.

#### Acceptance Criteria

1. THE Settings_Store SHALL present a list of available audio input devices to the user.
2. WHEN the user selects an audio input device, THE Audio_Engine SHALL use the selected device for subsequent Recording_Sessions.
3. THE Settings_Store SHALL persist the selected audio input device across application restarts.
4. IF the persisted audio input device is not available at launch, THEN THE Audio_Engine SHALL use the system default input device and THE Menu_Bar_Controller SHALL notify the user.
5. WHEN a new audio input device is connected or an existing device is disconnected, THE Audio_Engine SHALL update the available device list.

### Requirement 9: Visual Feedback During Recording

**User Story:** As a user, I want visual indicators during recording and transcription so that I know the app is actively listening and processing.

#### Acceptance Criteria

1. WHEN a Recording_Session begins, THE Recording_Overlay SHALL appear as a floating window displaying a recording indicator.
2. WHILE a Recording_Session is active, THE Recording_Overlay SHALL display a real-time audio waveform or level meter reflecting microphone input.
3. WHILE the State_Manager is in the processing state, THE Recording_Overlay SHALL display a transcription-in-progress indicator.
4. WHEN the State_Manager transitions to idle after a completed cycle, THE Recording_Overlay SHALL dismiss automatically.
5. WHEN the State_Manager transitions to the error state, THE Recording_Overlay SHALL display the error message for 3 seconds before dismissing.

### Requirement 10: Settings and Preferences

**User Story:** As a user, I want a settings interface to configure hotkeys, audio devices, model selection, and launch behavior so that I can tailor Wisp to my workflow.

#### Acceptance Criteria

1. WHEN the user opens settings, THE Wisp application SHALL display a preferences window with sections for: Hotkey Configuration, Audio Device, Whisper Model, and General.
2. THE Settings_Store SHALL persist all user preferences using UserDefaults.
3. WHEN the user enables "Launch at Login," THE Wisp application SHALL register itself to start automatically at macOS login using ServiceManagement.
4. WHEN the user disables "Launch at Login," THE Wisp application SHALL unregister itself from macOS login items.
5. WHEN the user changes any setting, THE Wisp application SHALL apply the change immediately without requiring an application restart.

### Requirement 11: Privacy and Data Handling

**User Story:** As a privacy-conscious user, I want assurance that all voice data stays on my machine and temporary files are cleaned up so that my conversations remain private.

#### Acceptance Criteria

1. THE Wisp application SHALL perform all audio capture, transcription, and text insertion without establishing any outbound network connections for data processing.
2. WHEN a Recording_Session completes (successfully or with an error), THE Audio_Engine SHALL delete any temporary audio files from disk within 5 seconds.
3. THE Wisp application SHALL function fully without an active internet connection, provided a Whisper_Model is already downloaded.
4. THE Wisp application SHALL NOT log, persist, or transmit any transcribed text content beyond the immediate insertion operation.

### Requirement 12: Error Recovery and Resilience

**User Story:** As a user, I want Wisp to handle errors gracefully so that temporary issues do not require restarting the application.

#### Acceptance Criteria

1. IF an error occurs during a Recording_Session, THEN THE State_Manager SHALL transition to the error state, display the error, and return to idle within 5 seconds.
2. IF the Whisper_Service encounters a model loading error, THEN THE Whisper_Service SHALL attempt to reload the model once before reporting failure.
3. WHEN the macOS system wakes from sleep, THE Hotkey_Monitor SHALL verify hotkey registration and re-register if necessary.
4. IF the Audio_Engine encounters a hardware error during recording, THEN THE Audio_Engine SHALL stop the Recording_Session cleanly and THE State_Manager SHALL notify the user.
5. THE State_Manager SHALL prevent concurrent Recording_Sessions; WHEN a new Recording_Session is requested while one is active, THE State_Manager SHALL ignore the request.

### Requirement 13: First-Launch Onboarding Experience

**User Story:** As a new user, I want a guided, polished onboarding experience on first launch so that I can set up Wisp step by step and feel confident the app is ready to use.

#### Acceptance Criteria

1. WHEN Wisp launches and no prior onboarding has been completed, THE Onboarding_Flow SHALL present a multi-step setup wizard as a dedicated window.
2. THE Onboarding_Flow SHALL display a step indicator showing the current step, total number of steps, and progress through the setup process.
3. THE Onboarding_Flow SHALL present each permission request (microphone, accessibility) on its own dedicated step with a plain-language explanation of why the permission is needed and what functionality it enables.
4. WHEN the user grants a permission during the Onboarding_Flow, THE Onboarding_Flow SHALL display a confirmation of the granted permission and enable the "Continue" action to proceed to the next step.
5. WHILE a required permission (microphone or accessibility) has not been granted, THE Onboarding_Flow SHALL keep the "Continue" action disabled on that step.
6. THE Onboarding_Flow SHALL include a model selection step where the user picks a Whisper_Model from the available sizes, with a description of each model's size and quality trade-off.
7. WHEN the user selects a Whisper_Model during onboarding, THE Onboarding_Flow SHALL download the selected model and display real-time download progress including percentage and estimated time remaining.
8. WHILE the selected Whisper_Model is downloading, THE Onboarding_Flow SHALL keep the "Continue" action disabled until the download completes successfully.
9. WHEN the model download completes, THE Onboarding_Flow SHALL present an interactive test-dictation step where the user can press the hotkey, speak a short phrase, and see the transcribed text appear in the onboarding window.
10. THE Onboarding_Flow SHALL allow the user to skip the test-dictation step but SHALL NOT allow skipping the permission or model-download steps.
11. WHEN all required onboarding steps are completed, THE Onboarding_Flow SHALL display a completion screen confirming that Wisp is configured and ready to use.
12. WHEN the user dismisses the completion screen, THE Settings_Store SHALL persist the onboarding-completed flag and THE Onboarding_Flow SHALL not appear on subsequent launches.
13. THE Onboarding_Flow SHALL use smooth animated transitions between steps and present a visually cohesive design consistent with macOS Human Interface Guidelines.
14. IF the user force-quits Wisp during the Onboarding_Flow, THEN THE Onboarding_Flow SHALL resume from the last incomplete required step on the next launch.
15. IF a model download fails during the Onboarding_Flow, THEN THE Onboarding_Flow SHALL display the error and offer a retry action without leaving the current step.

### Requirement 14: Modern macOS Visual Design and UI Quality

**User Story:** As a user, I want Wisp to look and feel like a premium, native macOS 26 application with a modern, polished interface so that it blends seamlessly into my desktop environment.

#### Acceptance Criteria

1. THE UI_Theme_Engine SHALL use SF Symbols for all iconography throughout the Wisp application to maintain visual consistency with macOS system applications.
2. THE Menu_Bar_Controller SHALL display a custom menu bar icon rendered as a template image that appears sharp at @1x, @2x, and @3x Retina resolutions.
3. THE UI_Theme_Engine SHALL apply Liquid_Glass materials (.ultraThinMaterial, .regularMaterial) to all overlay and popover surfaces, consistent with the macOS 26 Tahoe design language.
4. WHEN the macOS system appearance changes between light and dark mode, THE UI_Theme_Engine SHALL adapt all Wisp views to match the active system appearance without requiring an application restart.
5. THE UI_Theme_Engine SHALL use semantic system colors (e.g., .primary, .secondary, .accent) for all text and UI elements so that colors adapt correctly to light mode, dark mode, and increased-contrast accessibility settings.
6. THE Wisp application SHALL use SF Pro system fonts with Dynamic Type support for all text rendering, following the macOS typographic scale for consistent hierarchy.
7. THE Wisp application SHALL build all user-facing views using SwiftUI, resorting to AppKit only for system-level integrations (NSStatusItem, global hotkey registration, accessibility API access).
8. WHEN the Recording_Overlay appears or dismisses, THE UI_Theme_Engine SHALL animate the transition using SwiftUI spring animations with a duration no longer than 300 milliseconds.
9. WHEN the application state changes (idle, recording, processing), THE Menu_Bar_Controller icon and THE Recording_Overlay SHALL transition between visual states using smooth, interruptible SwiftUI animations.
10. THE Recording_Overlay SHALL render as a compact, borderless floating window with rounded corners and a drop shadow consistent with macOS system window styling.
11. THE Wisp application SHALL maintain consistent spacing using an 8-point grid system and standard macOS layout margins across all views.
12. THE Onboarding_Flow and Settings views SHALL apply Liquid_Glass translucency to their window backgrounds, matching the layered depth aesthetic of macOS 26 system preferences.
13. WHEN the user interacts with buttons or controls in any Wisp view, THE UI_Theme_Engine SHALL provide visual feedback (highlight, scale, or opacity change) within 100 milliseconds of the interaction.

### Requirement 15: Technology Stack and Architecture Constraints

**User Story:** As a developer, I want a strict, modern Swift-only technology stack so that the codebase is consistent, maintainable, and takes full advantage of Swift 6 language features.

#### Acceptance Criteria

1. THE Wisp application SHALL compile under Swift 6 with strict concurrency checking enabled across all targets.
2. THE Wisp application SHALL build all user-facing views exclusively with SwiftUI; AppKit types (such as NSStatusItem) SHALL only be used where SwiftUI provides no equivalent API.
3. THE Wisp application SHALL use Swift Concurrency (async/await, actors, structured concurrency) for all asynchronous operations; Grand Central Dispatch, DispatchQueue, and Combine-based asynchronous flows SHALL NOT be used.
4. THE Wisp application SHALL use structured concurrency patterns (async let, TaskGroup, AsyncStream) for all concurrent operations. Task {} inside AsyncStream closures is permitted as it represents structured concurrency (task is scoped to stream lifetime with automatic cancellation). Task.detached {} is prohibited.
5. THE Wisp application SHALL use the swift-testing framework for all automated tests; XCTest SHALL NOT be used.
6. THE Whisper_Service SHALL use WhisperKit as the sole speech-to-text engine for on-device transcription.
7. THE Wisp application SHALL contain no Objective-C bridging headers, no @objc annotations, and no NSObject subclasses unless a specific macOS system API has no pure-Swift alternative.
8. THE Wisp application SHALL be written in 100% pure Swift, preferring Swift-native APIs over Foundation or AppKit equivalents where a Swift-native option exists.
9. THE Wisp application SHALL use Swift Package Manager as the sole dependency management tool.
10. THE Wisp application SHALL target macOS 26 (Tahoe) as the minimum deployment target.
11. THE Wisp application SHALL use the @Observable macro (Observation framework) for all observable state; ObservableObject and Combine-based observation SHALL NOT be used.

### Requirement 16: Multi-Language Transcription Support

**User Story:** As a multilingual user, I want Wisp to transcribe speech in multiple languages so that I can dictate in whichever language I am speaking without manual reconfiguration.

#### Acceptance Criteria

1. THE Whisper_Service SHALL support transcription in all languages supported by the active Whisper_Model.
2. WHEN auto-detect mode is enabled, THE Whisper_Service SHALL identify the spoken language from the audio and transcribe using the detected language without user intervention.
3. THE Settings_Store SHALL default to auto-detect mode for language selection on first launch.
4. WHEN the user selects a specific language from the language selection control, THE Whisper_Service SHALL use the selected language for transcription instead of auto-detecting.
5. WHEN the user selects a specific language, THE Settings_Store SHALL persist the selected language as the default for subsequent Recording_Sessions and application restarts.
6. WHEN auto-detect mode is disabled and a language has been previously selected, THE Settings_Store SHALL restore the selected language on application restart.
7. THE Menu_Bar_Controller SHALL display the currently active language (or an auto-detect indicator) in the menu bar dropdown so the user can identify the active language at a glance.
8. WHEN the user opens the menu bar dropdown or the Recording_Overlay, THE Menu_Bar_Controller SHALL provide a language selection control allowing the user to switch languages or toggle auto-detect mode without opening the full settings window.
9. WHEN the user changes the language during an idle state, THE Whisper_Service SHALL apply the new language selection to the next Recording_Session without interrupting the user's workflow.
10. THE Settings_Store SHALL provide a "Pin Language" option that disables auto-detect and locks transcription to the pinned language until the user changes the setting.
11. IF the user enables auto-detect mode after pinning a language, THEN THE Settings_Store SHALL clear the pinned language and THE Whisper_Service SHALL resume automatic language detection.

### Requirement 17: Accessibility Support for Visually Impaired Users

**User Story:** As a visually impaired user, I want all Wisp UI elements to be fully accessible so that I can use the application effectively with assistive technologies.

#### Acceptance Criteria

1. THE Wisp application SHALL provide descriptive VoiceOver accessibility labels and hints on all UI elements, including buttons, controls, status indicators, and informational text.
2. THE Wisp application SHALL make all interactive controls navigable via keyboard using Tab, arrow keys, Enter, and Escape without requiring a mouse or trackpad.
3. WHEN the State_Manager transitions between states (recording, processing, idle, error), THE Recording_Overlay SHALL announce the state change (e.g., "Recording started," "Processing speech," "Text inserted") via VoiceOver accessibility notifications.
4. WHEN the macOS Increase Contrast accessibility setting is enabled, THE UI_Theme_Engine SHALL render all UI elements with higher contrast borders, backgrounds, and text colors that meet the increased contrast requirements.
5. WHILE the macOS Reduce Motion accessibility setting is enabled, THE UI_Theme_Engine SHALL disable all non-essential animations, including spring transitions, waveform animations, and overlay entrance effects.
6. WHILE the macOS Reduce Transparency accessibility setting is enabled, THE UI_Theme_Engine SHALL replace all Liquid_Glass translucent materials with opaque background fills.
7. THE Wisp application SHALL respect the macOS Dynamic Type and text size accessibility settings, scaling all text elements proportionally to the user-configured text size.
8. WHILE keyboard navigation is active, THE UI_Theme_Engine SHALL display a visible focus indicator on the currently focused interactive element.
9. THE Onboarding_Flow SHALL be fully navigable via VoiceOver, with each step, instruction, button, and progress indicator properly labeled and announced.
10. THE Menu_Bar_Controller SHALL expose all menu bar interactions (icon activation, dropdown menu items, language selection) as accessible elements navigable via VoiceOver.
11. WHEN an error message is displayed or a status change occurs, THE Wisp application SHALL post the message to assistive technologies using appropriate accessibility notification APIs so that screen readers announce the change.
12. THE Wisp application SHALL size all interactive controls (buttons, toggles, menu items) to a minimum target size of 44×44 points, following Apple Human Interface Guidelines for accessibility.

### Requirement 18: Xcode MCP Tool Integration for Development Workflow

**User Story:** As a developer implementing Wisp, I want all code editing, building, testing, and debugging operations to be performed through the Xcode MCP tool starting from a user-provided Xcode project so that the development workflow is consistent and leverages Xcode's native capabilities.

#### Acceptance Criteria

1. THE user SHALL manually create the initial Xcode project and skeleton app structure before implementation begins.
2. WHEN implementation begins, THE implementation process SHALL use the Xcode MCP tool to discover the existing project structure, targets, and files created by the user.
3. THE implementation process SHALL start all development work from the existing user-provided Xcode project without creating a new project.
4. THE implementation process SHALL use the Xcode MCP tool for all file creation operations within the existing Xcode project structure.
5. THE implementation process SHALL use the Xcode MCP tool for all code editing operations, including creating new Swift files, modifying existing files, and refactoring code.
6. THE implementation process SHALL use the Xcode MCP tool for all build operations, including compiling the application, resolving Swift Package Manager dependencies, and generating build artifacts.
7. THE implementation process SHALL use the Xcode MCP tool for all testing operations, including running swift-testing test suites and reporting test results.
8. THE implementation process SHALL use the Xcode MCP tool for debugging operations, including setting breakpoints, inspecting variables, and analyzing runtime behavior.
9. THE implementation process SHALL NOT create or modify files directly in the filesystem outside of the Xcode MCP tool's file management capabilities.
10. THE implementation process SHALL use the Xcode MCP tool to manage project configuration, including build settings, target configuration, and code signing settings.
11. THE implementation process SHALL use the Xcode MCP tool to add and manage Swift Package Manager dependencies required by the Wisp application.
12. WHEN compilation errors or warnings occur, THE implementation process SHALL use the Xcode MCP tool to retrieve diagnostic information and resolve issues.
