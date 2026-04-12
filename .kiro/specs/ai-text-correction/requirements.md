# Requirements Document

## Introduction

This feature adds an opt-in AI text correction step to Wispr's post-transcription pipeline. After speech-to-text transcription and filler word removal, dictated text is passed through Apple's on-device FoundationModels language model to correct grammar, remove hesitations and repetitions, and improve spoken-to-written fluency. The feature runs entirely on-device via Apple Neural Engine, requires macOS 26+ with Apple Intelligence enabled, and gracefully degrades when unavailable. Audio and text never leave the device, preserving Wispr's privacy guarantees.

## Glossary

- **AI Text Correction**: The on-device LLM-based post-processing step that corrects grammar and cleans up spoken text before insertion.
- **FoundationModels**: Apple's macOS 26+ framework providing on-device language model inference via `SystemLanguageModel`.
- **TextCorrectionService**: The new service that wraps FoundationModels for text correction, exposing availability status and a correction method.
- **Correction Style**: The degree of modification applied — minimal (grammar and typo fixes only) vs. full rephrase (restructure for written fluency).
- **Apple Intelligence**: Apple's on-device AI capability required for FoundationModels to be available.
- **LanguageModelSession**: The FoundationModels class that manages a conversation with the on-device model, accepting system instructions and user prompts.

## Requirements

### Requirement 1: Text Correction Setting Persistence

**User Story:** As a user, I want my AI text correction preference to be saved between app launches, so that I do not have to reconfigure it each time I open Wispr.

#### Acceptance Criteria

1. THE SettingsStore SHALL persist an `aiTextCorrectionEnabled` boolean property with a default value of `false`.
2. THE SettingsStore SHALL persist an `aiTextCorrectionStyle` property of type `CorrectionStyle` with a default value of `.minimal`.
3. WHEN the user changes `aiTextCorrectionEnabled`, THE SettingsStore SHALL persist the new value to UserDefaults immediately.
4. WHEN the user changes `aiTextCorrectionStyle`, THE SettingsStore SHALL persist the new value to UserDefaults immediately.
5. WHEN Wispr launches, THE SettingsStore SHALL load the persisted `aiTextCorrectionEnabled` and `aiTextCorrectionStyle` values from UserDefaults.

### Requirement 2: Settings UI

**User Story:** As a user, I want to configure AI text correction from the Settings panel, including seeing whether my device supports it, so that I can enable the feature when available and choose my preferred correction style.

#### Acceptance Criteria

1. THE SettingsView SHALL display a toggle labeled "AI Text Correction" in the After Transcription section, positioned after "Remove Filler Words" and before "Auto-Insert Suffix".
2. WHEN Apple Intelligence is not available on the device, THE SettingsView SHALL display the toggle as disabled with an explanatory message indicating the reason (e.g., "Requires Apple Intelligence" or "Apple Intelligence not enabled").
3. WHEN `aiTextCorrectionEnabled` is on, THE SettingsView SHALL display a Picker for correction style with options "Minimal" and "Full Rephrase".
4. WHEN `aiTextCorrectionEnabled` is off or Apple Intelligence is unavailable, THE SettingsView SHALL hide the correction style picker.
5. THE SettingsView toggle SHALL include an accessibility hint describing the feature purpose.
6. THE SettingsView SHALL bind the toggle to `SettingsStore.aiTextCorrectionEnabled` and the picker to `SettingsStore.aiTextCorrectionStyle`.

### Requirement 3: Text Correction Applied in Pipeline

**User Story:** As a user, I want my dictated text to be automatically corrected for grammar and fluency before insertion, so that what appears in my document reads as polished written text.

#### Acceptance Criteria

1. WHILE `aiTextCorrectionEnabled` is true AND the on-device model is available, WHEN the StateManager completes filler word removal and the cleaned text is non-empty, THE StateManager SHALL pass the text to TextCorrectionService for correction before applying auto-suffix.
2. WHILE `aiTextCorrectionEnabled` is false, THE StateManager SHALL skip the correction step entirely and not invoke the TextCorrectionService.
3. THE TextCorrectionService SHALL preserve the user's intended meaning and not add, remove, or change factual content.
4. THE StateManager SHALL apply text correction in both push-to-talk mode (hotkey release) and hands-free mode (end-of-utterance detection).
5. THE pipeline order SHALL be: Transcription → Filler Word Removal → AI Text Correction → Auto-Suffix → Text Insertion → Auto-Send Enter.

### Requirement 4: Graceful Degradation

**User Story:** As a user on a device that does not support Apple Intelligence, I want the feature to degrade gracefully without errors, so that my dictation workflow is unaffected.

#### Acceptance Criteria

1. WHEN the on-device model is not available (device not eligible, Apple Intelligence not enabled, or model not ready), THE TextCorrectionService SHALL return the original text unchanged.
2. WHEN the on-device model becomes unavailable during a correction attempt (e.g., throws an error), THE TextCorrectionService SHALL return the original text unchanged and log a warning.
3. THE SettingsView SHALL check model availability at display time and disable the toggle when unavailable.
4. WHEN `aiTextCorrectionEnabled` is true but the model is unavailable at correction time, THE StateManager SHALL silently skip correction and proceed with the uncorrected text.

### Requirement 5: Latency Handling and UI Feedback

**User Story:** As a user, I want visual feedback when AI correction is in progress, so I understand why there is a brief delay before my text appears.

#### Acceptance Criteria

1. WHILE AI text correction is in progress, THE recording overlay SHALL display a "Correcting…" status instead of the default "Processing…" text.
2. THE TextCorrectionService SHALL implement a timeout of 5 seconds; if the on-device model does not respond within the timeout, THE service SHALL return the original uncorrected text.
3. WHEN the correction step completes (whether by success, failure, or timeout), THE recording overlay SHALL revert to the default processing status before proceeding to text insertion.

### Requirement 6: Correction Styles

**User Story:** As a user, I want to choose how aggressively the AI corrects my text, so I can balance between minimal touch-ups and full rephrasing for written fluency.

#### Acceptance Criteria

1. THE TextCorrectionService SHALL support two correction styles: `.minimal` and `.fullRephrase`.
2. WHEN style is `.minimal`, THE service SHALL direct the on-device model to fix only grammar errors, typos, and obvious speech artifacts (false starts, repetitions) while preserving the original phrasing and tone.
3. WHEN style is `.fullRephrase`, THE service SHALL direct the on-device model to rewrite the text for written fluency — improving sentence structure and flow — while preserving the original meaning and key details.
4. THE correction style SHALL be configurable via `SettingsStore.aiTextCorrectionStyle` and surfaced in the Settings UI.

### Requirement 7: Restore Defaults

**User Story:** As a user, I want the Restore Defaults action to reset AI text correction settings, so that I can return to the original configuration.

#### Acceptance Criteria

1. WHEN the user activates "Restore Defaults" in SettingsView, THE SettingsStore SHALL reset `aiTextCorrectionEnabled` to `false`.
2. WHEN the user activates "Restore Defaults" in SettingsView, THE SettingsStore SHALL reset `aiTextCorrectionStyle` to `.minimal`.
