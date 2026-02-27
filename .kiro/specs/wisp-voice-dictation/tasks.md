# Implementation Plan: Wisp Voice Dictation

## Overview

This implementation plan breaks down the Wisp voice dictation application into discrete, incremental coding tasks. Each task builds on previous work, with early validation through code and testing. The app will be built using Swift 6, SwiftUI, Swift Concurrency, and WhisperKit, targeting macOS 26 (Tahoe).

**IMPORTANT:** The user will manually create the initial Xcode project and skeleton app structure before starting Task 1. All subsequent tasks use the Xcode MCP tool for file operations, building, testing, and debugging.

## Tasks

- [x] 1. Discover and verify existing Xcode project structure
  - Use Xcode MCP tool to list project files and targets
  - Verify Swift 6 and macOS 26 target configuration
  - Verify Info.plist exists with LSUIElement and required permissions (microphone, accessibility)
  - Verify strict concurrency checking is enabled in build settings
  - Verify directory structure includes: Models/, Services/, UI/, Utilities/
  - Verify Swift Package Manager dependencies (WhisperKit) are configured
  - _Requirements: 15.1, 15.2, 15.8, 15.9_
  - _Note: User will manually create the initial Xcode project before starting tasks_

- [x] 2. Implement core data models and error types
  - [x] 2.1 Create data model types using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift files in Models/ directory
    - Implement `AppStateType`, `RecordingSession`, `WhisperModelInfo`, `ModelStatus`, `DownloadProgress`, `TranscriptionResult`, `TranscriptionLanguage`, `AudioInputDevice`, `PermissionStatus`, `OnboardingStep` enums and structs
    - Ensure all types conform to `Sendable` for Swift 6 concurrency
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 1.1, 2.1, 3.1, 7.1, 8.1, 16.1_
  
  - [x] 2.2 Create WispError enum using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Models/ directory
    - Define all error cases: permissions, audio, transcription, text insertion, hotkey, model management
    - Conform to `Error`, `Sendable`, `Equatable`
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 12.1, 12.2, 12.4_

- [x] 3. Implement SettingsStore for persistent preferences
  - [x] 3.1 Create SettingsStore class using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement `@MainActor @Observable` class with UserDefaults backing
    - Add properties: hotkeyKeyCode, hotkeyModifiers, selectedAudioDeviceUID, activeModelName, languageMode, launchAtLogin, onboardingCompleted, onboardingLastStep
    - Implement save() and load() methods
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 1.3, 7.11, 8.3, 10.2, 13.12_
  
  - [x] 3.2 Write unit tests for SettingsStore using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test persistence and retrieval of all settings
    - Test default values
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 10.2_

- [x] 4. Implement PermissionManager
  - [x] 4.1 Create PermissionManager class using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement `@MainActor @Observable` class
    - Add microphoneStatus and accessibilityStatus published properties
    - Implement checkPermissions(), requestMicrophoneAccess(), openAccessibilitySettings()
    - Implement startMonitoringPermissionChanges() using async polling
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 6.1, 6.2, 6.3, 6.4, 6.5_
  
  - [x] 4.2 Write unit tests for PermissionManager using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test permission status detection
    - Test permission request flows
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 6.1, 6.2_

- [x] 5. Implement AudioEngine actor
  - [x] 5.1 Create AudioEngine actor with AVAudioEngine integration using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement actor with AVAudioEngine lifecycle management
    - Implement setInputDevice(), availableInputDevices()
    - Implement startCapture() returning AsyncStream<Float> for audio levels
    - Implement stopCapture() returning recorded Data
    - Implement cancelCapture() for cleanup
    - Implement startDeviceMonitoring() for device change detection
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 2.1, 2.2, 2.3, 2.4, 2.5, 2.6, 8.1, 8.2, 8.5_
  
  - [x] 5.2 Write unit tests for AudioEngine using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test device enumeration
    - Test capture lifecycle (mock AVAudioEngine)
    - Test device fallback behavior
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 2.4, 2.5_

- [x] 6. Checkpoint - Verify core services compile and basic tests pass
  - Use Xcode MCP tool to build the project
  - Use Xcode MCP tool to run all tests
  - Use Xcode MCP tool to check for diagnostics and warnings
  - Ensure all tests pass, ask the user if questions arise.

- [x] 7. Implement WhisperService actor
  - [x] 7.1 Create WhisperService actor with WhisperKit integration using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement actor with WhisperKit instance management
    - Implement availableModels() returning hardcoded model list
    - Implement loadModel() and switchModel() for model lifecycle
    - Implement validateModelIntegrity() for post-download validation
    - Implement modelStatus() and activeModel() query methods
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 3.1, 3.2, 7.1, 7.5, 7.6, 7.7, 7.12_
  
  - [x] 7.2 Implement model download functionality using Xcode MCP tool
    - Use Xcode MCP tool to add methods to WhisperService
    - Implement downloadModel() with progress callback using WhisperKit download APIs
    - Implement deleteModel() with file system cleanup
    - Handle concurrent download tasks with task dictionary
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 7.2, 7.3, 7.4, 7.8, 7.9, 7.10_
  
  - [x] 7.3 Implement transcription functionality using Xcode MCP tool
    - Use Xcode MCP tool to add transcribe() method to WhisperService
    - Implement transcribe() method accepting audioData and TranscriptionLanguage
    - Handle auto-detect, specific language, and pinned language modes
    - Return TranscriptionResult with text and detected language
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 3.1, 3.3, 3.4, 3.5, 16.1, 16.2, 16.4_
  
  - [x] 7.4 Write unit tests for WhisperService using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test model lifecycle (load, switch, unload)
    - Test download progress tracking
    - Test model deletion and fallback logic
    - Mock WhisperKit for transcription tests
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 7.6, 7.9, 7.12_

- [x] 8. Implement TextInsertionService actor
  - [x] 8.1 Create TextInsertionService actor using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement insertText() with Accessibility API primary path
    - Implement insertViaAccessibility() using AXUIElement APIs
    - Implement insertViaClipboard() with pasteboard + simulated ⌘V
    - Implement restorePasteboard() with async delay for cleanup
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 4.1, 4.2, 4.3, 4.4, 4.5_
  
  - [x] 8.2 Write unit tests for TextInsertionService using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test clipboard fallback logic
    - Test pasteboard restoration
    - Mock AXUIElement for accessibility tests
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 4.2, 4.5_

- [ ] 9. Implement HotkeyMonitor
  - [ ] 9.1 Create HotkeyMonitor class with Carbon Event API integration using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement `@MainActor` class
    - Implement register() using Carbon RegisterEventHotKey
    - Implement unregister() for cleanup
    - Implement updateHotkey() for dynamic hotkey changes
    - Implement verifyRegistration() for post-sleep validation
    - Add onHotkeyDown and onHotkeyUp closures for event callbacks
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 1.1, 1.2, 1.4, 1.5, 12.3_
  
  - [ ] 9.2 Write unit tests for HotkeyMonitor using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test hotkey registration and unregistration
    - Test conflict detection
    - Test callback invocation (mock Carbon APIs)
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 1.4, 1.5_

- [ ] 10. Checkpoint - Verify all service actors compile and tests pass
  - Use Xcode MCP tool to build the project
  - Use Xcode MCP tool to run all tests
  - Use Xcode MCP tool to check for diagnostics and warnings
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 11. Implement StateManager
  - [ ] 11.1 Create StateManager class using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Services/ directory
    - Implement `@MainActor @Observable` class
    - Add published properties: appState, errorMessage, currentLanguage
    - Inject all service dependencies (AudioEngine, WhisperService, TextInsertionService, HotkeyMonitor, PermissionManager, SettingsStore)
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 1.1, 3.6, 9.3, 12.1, 12.5_
  
  - [ ] 11.2 Implement state machine methods using Xcode MCP tool
    - Use Xcode MCP tool to add methods to StateManager
    - Implement beginRecording() to start audio capture and transition to .recording
    - Implement endRecording() to stop capture, transition to .processing, call transcription, then text insertion
    - Implement handleError() to transition to .error state with message
    - Implement resetToIdle() to clean up and return to .idle
    - Wire up HotkeyMonitor callbacks to beginRecording/endRecording
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 1.1, 1.2, 2.1, 2.2, 3.1, 3.3, 4.1, 4.3, 12.1, 12.5_
  
  - [ ] 11.3 Write unit tests for StateManager using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test state transitions (idle → recording → processing → idle)
    - Test error handling and recovery
    - Test concurrent recording prevention
    - Mock all service dependencies
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 12.1, 12.5_

- [ ] 12. Implement UI Theme Engine
  - [ ] 12.1 Create UIThemeEngine utility using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in Utilities/ directory
    - Create utility class for managing Liquid Glass materials, semantic colors, SF Symbols
    - Implement system appearance change detection
    - Implement accessibility setting detection (Reduce Motion, Reduce Transparency, Increase Contrast)
    - Provide SwiftUI view modifiers for consistent theming
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 14.1, 14.3, 14.4, 14.5, 14.8, 14.9, 17.4, 17.5, 17.6_
  
  - [ ] 12.2 Write unit tests for UIThemeEngine using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test appearance adaptation
    - Test accessibility setting detection
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 14.4, 17.4, 17.5, 17.6_

- [ ] 13. Implement RecordingOverlay UI
  - [ ] 13.1 Create RecordingOverlay SwiftUI view and NSPanel wrapper using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift files in UI/ directory
    - Create borderless NSPanel with floating level
    - Create SwiftUI view with Liquid Glass material background
    - Display recording indicator, audio waveform/level meter, processing spinner, error messages
    - Consume AsyncStream<Float> from AudioEngine for real-time levels
    - Implement spring animations (≤300ms) for show/dismiss
    - Respect Reduce Motion and Reduce Transparency
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 9.1, 9.2, 9.3, 9.4, 9.5, 14.3, 14.8, 14.9, 14.10, 14.12_
  
  - [ ] 13.2 Write UI tests for RecordingOverlay using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test overlay appearance and dismissal
    - Test state transitions (recording → processing → idle/error)
    - Test accessibility labels and VoiceOver support
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 9.1, 9.4, 17.1, 17.3_

- [ ] 14. Implement MenuBarController
  - [ ] 14.1 Create MenuBarController with NSStatusItem using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in UI/ directory
    - Create NSStatusItem in menu bar
    - Load template icon (SF Symbol microphone) with @1x, @2x, @3x support
    - Implement icon state changes (idle, recording, processing)
    - Create dropdown menu with: Start/Stop Recording, Settings, Model Management, Language Selection, Quit
    - Wire menu actions to StateManager
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 5.1, 5.2, 5.3, 5.4, 5.5, 14.2, 14.9, 16.7, 16.8_
  
  - [ ] 14.2 Write UI tests for MenuBarController using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test menu item actions
    - Test icon state updates
    - Test accessibility labels for menu items
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 5.3, 5.4, 17.10_

- [ ] 15. Checkpoint - Verify core UI and menu bar integration
  - Use Xcode MCP tool to build the project
  - Use Xcode MCP tool to run all tests
  - Use Xcode MCP tool to check for diagnostics and warnings
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 16. Implement SettingsView
  - [ ] 16.1 Create SettingsView SwiftUI form using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in UI/ directory
    - Create SwiftUI Form with sections: Hotkey Configuration, Audio Device, Whisper Model, Language, General
    - Bind all controls to SettingsStore properties
    - Implement hotkey recorder control
    - Implement audio device picker
    - Implement model selection picker
    - Implement language selection (auto-detect, specific language, pin language)
    - Implement Launch at Login toggle with ServiceManagement integration
    - Apply Liquid Glass materials and semantic colors
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 10.1, 10.2, 10.3, 10.4, 10.5, 14.3, 14.5, 14.12, 16.3, 16.4, 16.5, 16.6, 16.9, 16.10, 16.11_
  
  - [ ] 16.2 Write UI tests for SettingsView using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test setting changes apply immediately
    - Test Launch at Login registration
    - Test keyboard navigation
    - Test accessibility labels
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 10.5, 17.2, 17.8_

- [ ] 17. Implement ModelManagementView
  - [ ] 17.1 Create ModelManagementView SwiftUI list using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in UI/ directory
    - Create SwiftUI List displaying all available models
    - Show model name, size, quality description, status (not downloaded / downloading % / downloaded / active)
    - Implement download button with progress indicator
    - Implement delete button with confirmation
    - Implement switch-active action
    - Handle model deletion fallback logic (switch to next smallest before delete)
    - Apply Liquid Glass materials
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 7.2, 7.3, 7.4, 7.6, 7.7, 7.8, 7.9, 7.10, 14.3, 14.12_
  
  - [ ] 17.2 Write UI tests for ModelManagementView using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test model download flow
    - Test model deletion and fallback
    - Test active model switching
    - Test accessibility labels
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 7.8, 7.9, 17.1_

- [ ] 18. Implement OnboardingFlow
  - [ ] 18.1 Create OnboardingFlow multi-step wizard using Xcode MCP tool
    - Use Xcode MCP tool to create new Swift file in UI/ directory
    - Create SwiftUI view with step navigation (Welcome, Microphone Permission, Accessibility Permission, Model Selection, Test Dictation, Completion)
    - Implement step indicator showing current step and progress
    - Implement Continue button with conditional enabling based on step completion
    - Apply Liquid Glass materials and smooth animated transitions
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 13.1, 13.2, 13.13, 14.3, 14.8, 14.12_
  
  - [ ] 18.2 Implement permission request steps using Xcode MCP tool
    - Use Xcode MCP tool to add permission steps to OnboardingFlow
    - Create Microphone Permission step with explanation and request button
    - Create Accessibility Permission step with explanation and system settings link
    - Disable Continue until permissions granted
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 13.3, 13.4, 13.5_
  
  - [ ] 18.3 Implement model selection and download step using Xcode MCP tool
    - Use Xcode MCP tool to add model selection step to OnboardingFlow
    - Create Model Selection step with model list and descriptions
    - Implement download with real-time progress (percentage, estimated time)
    - Disable Continue until download completes
    - Handle download failures with retry action
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 13.6, 13.7, 13.8, 13.15_
  
  - [ ] 18.4 Implement test dictation step using Xcode MCP tool
    - Use Xcode MCP tool to add test dictation step to OnboardingFlow
    - Create Test Dictation step with instructions and hotkey prompt
    - Display transcribed text in onboarding window
    - Allow skip but not for required steps
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 13.9, 13.10_
  
  - [ ] 18.5 Implement completion and resume logic using Xcode MCP tool
    - Use Xcode MCP tool to add completion logic to OnboardingFlow
    - Create Completion step with confirmation message
    - Persist onboardingCompleted flag on dismissal
    - Persist onboardingLastStep for resume on force-quit
    - Resume from last incomplete step on next launch
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 13.11, 13.12, 13.14_
  
  - [ ] 18.6 Write UI tests for OnboardingFlow using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test step navigation and progress indicator
    - Test Continue button enabling/disabling
    - Test resume from interrupted onboarding
    - Test accessibility labels and VoiceOver navigation
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 13.2, 13.14, 17.9_

- [ ] 19. Checkpoint - Verify all UI views compile and render correctly
  - Use Xcode MCP tool to build the project
  - Use Xcode MCP tool to run all tests
  - Use Xcode MCP tool to check for diagnostics and warnings
  - Ensure all tests pass, ask the user if questions arise.

- [ ] 20. Implement application lifecycle and wiring
  - [ ] 20.1 Create WispApp main entry point using Xcode MCP tool
    - Use Xcode MCP tool to create or modify main App file
    - Create SwiftUI App struct with @main
    - Set NSApplication.ActivationPolicy.accessory for menu bar-only mode
    - Initialize all services (StateManager, AudioEngine, WhisperService, etc.)
    - Show OnboardingFlow on first launch, otherwise initialize menu bar
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 5.6, 13.1, 13.12_
  
  - [ ] 20.2 Wire StateManager to UI components using Xcode MCP tool
    - Use Xcode MCP tool to modify UI components
    - Connect StateManager to RecordingOverlay for state-driven display
    - Connect StateManager to MenuBarController for icon updates
    - Connect HotkeyMonitor callbacks to StateManager methods
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 1.1, 1.2, 5.2, 9.1, 9.3_
  
  - [ ] 20.3 Implement privacy and cleanup logic using Xcode MCP tool
    - Use Xcode MCP tool to modify AudioEngine and related services
    - Implement temporary audio file cleanup in AudioEngine after recording
    - Ensure no network connections for transcription
    - Verify no logging or persistence of transcribed text
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 11.1, 11.2, 11.3, 11.4_
  
  - [ ] 20.4 Write integration tests for application lifecycle using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test full recording → transcription → insertion flow
    - Test error recovery and state transitions
    - Test onboarding completion and skip
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 12.1, 13.12_

- [ ] 21. Implement accessibility support
  - [ ] 21.1 Add VoiceOver labels and hints to all UI elements using Xcode MCP tool
    - Use Xcode MCP tool to modify all UI files
    - Add accessibility labels to all buttons, controls, status indicators
    - Add accessibility hints for non-obvious interactions
    - Implement accessibility notifications for state changes
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 17.1, 17.3, 17.11_
  
  - [ ] 21.2 Implement keyboard navigation using Xcode MCP tool
    - Use Xcode MCP tool to modify UI files
    - Ensure all interactive controls are Tab-navigable
    - Implement visible focus indicators
    - Support Enter/Escape for primary/cancel actions
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 17.2, 17.8_
  
  - [ ] 21.3 Implement accessibility setting adaptations using Xcode MCP tool
    - Use Xcode MCP tool to modify UIThemeEngine and UI files
    - Implement Increase Contrast mode with higher contrast borders and backgrounds
    - Implement Reduce Motion mode disabling non-essential animations
    - Implement Reduce Transparency mode replacing Liquid Glass with opaque fills
    - Implement Dynamic Type support for text scaling
    - Ensure 44×44pt minimum touch target size for all controls
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 17.4, 17.5, 17.6, 17.7, 17.12_
  
  - [ ] 21.4 Write accessibility tests using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test VoiceOver navigation through all views
    - Test keyboard navigation
    - Test accessibility setting adaptations
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 17.1, 17.2, 17.4, 17.5, 17.6_

- [ ] 22. Implement multi-language transcription support
  - [ ] 22.1 Add language selection UI to menu bar and settings using Xcode MCP tool
    - Use Xcode MCP tool to modify MenuBarController and SettingsView
    - Add language picker to MenuBarController dropdown
    - Add language section to SettingsView
    - Display current language or auto-detect indicator in menu
    - Implement pin/unpin language toggle
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 16.3, 16.7, 16.8, 16.9, 16.10, 16.11_
  
  - [ ] 22.2 Integrate language selection with WhisperService using Xcode MCP tool
    - Use Xcode MCP tool to modify WhisperService and StateManager
    - Pass TranscriptionLanguage to WhisperService.transcribe()
    - Handle auto-detect, specific language, and pinned language modes
    - Persist language selection in SettingsStore
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 16.2, 16.4, 16.5, 16.6_
  
  - [ ] 22.3 Write tests for multi-language support using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test language selection persistence
    - Test auto-detect mode
    - Test pinned language mode
    - Mock WhisperKit for language detection tests
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 16.2, 16.4, 16.5_

- [ ] 23. Implement error recovery and resilience
  - [ ] 23.1 Add error handling to all service actors using Xcode MCP tool
    - Use Xcode MCP tool to modify service files
    - Implement model reload retry in WhisperService
    - Implement audio device fallback in AudioEngine
    - Implement hotkey re-registration in HotkeyMonitor after sleep
    - Implement concurrent recording prevention in StateManager
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 12.1, 12.2, 12.3, 12.4, 12.5_
  
  - [ ] 23.2 Write tests for error recovery using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test model reload retry
    - Test audio device fallback
    - Test hotkey re-registration
    - Test concurrent recording prevention
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 12.2, 12.3, 12.5_

- [ ] 24. Final integration and polish
  - [ ] 24.1 Implement Launch at Login functionality using Xcode MCP tool
    - Use Xcode MCP tool to modify SettingsStore or create helper
    - Use ServiceManagement framework to register/unregister login item
    - Wire to SettingsStore launchAtLogin property
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 10.3, 10.4_
  
  - [ ] 24.2 Add SF Symbols and template icons using Xcode MCP tool
    - Use Xcode MCP tool to add assets to project
    - Create menu bar template icon with @1x, @2x, @3x resolutions
    - Use SF Symbols throughout UI for consistency
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 14.1, 14.2_
  
  - [ ] 24.3 Verify Swift 6 strict concurrency compliance using Xcode MCP tool
    - Use Xcode MCP tool to check build settings
    - Enable strict concurrency checking in all targets
    - Use Xcode MCP tool to build and check for diagnostics
    - Resolve any data-race warnings
    - Ensure all types are properly Sendable
    - _Requirements: 15.1, 15.3_
  
  - [ ] 24.4 Verify no Objective-C bridging or legacy APIs using Xcode MCP tool
    - Use Xcode MCP tool to search codebase
    - Audit codebase for @objc annotations, NSObject subclasses
    - Ensure only unavoidable legacy APIs (Carbon hotkeys, AXUIElement) are used
    - Use Xcode MCP tool to build and verify compilation
    - _Requirements: 15.6, 15.7_
  
  - [ ] 24.5 Write end-to-end integration tests using Xcode MCP tool
    - Use Xcode MCP tool to create test file
    - Test full user flow: launch → onboarding → recording → transcription → insertion
    - Test settings persistence across app restarts
    - Test model management flows
    - Use Xcode MCP tool to run tests and verify results
    - _Requirements: 13.1, 13.12, 10.5_

- [ ] 25. Final checkpoint - Comprehensive testing and validation
  - Use Xcode MCP tool to build the entire project
  - Use Xcode MCP tool to run all tests
  - Use Xcode MCP tool to check for any remaining diagnostics or warnings
  - Use Xcode MCP tool to verify app runs correctly
  - Ensure all tests pass, ask the user if questions arise.

## Notes

- Tasks marked with `*` are optional and can be skipped for faster MVP
- Each task references specific requirements for traceability
- Checkpoints ensure incremental validation at key milestones
- All code must compile under Swift 6 strict concurrency checking
- All UI must respect macOS accessibility settings (Reduce Motion, Reduce Transparency, Increase Contrast, Dynamic Type)
- No Objective-C bridging except for unavoidable system APIs (Carbon hotkeys, AXUIElement)
- Use swift-testing framework for all tests, not XCTest
- **All file operations, building, testing, and debugging must use the Xcode MCP tool**
- The user will manually create the initial Xcode project before Task 1
- **UI tests should only be run at the very end of the project (Task 25), not during individual task execution. Only run unit tests during iterative development.**
- **Structured concurrency only**: Use structured patterns: async let, TaskGroup, AsyncStream, or direct async/await calls. Task {} inside AsyncStream closures is permitted (structured pattern). Task.detached {} is prohibited.
