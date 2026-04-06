# Requirements: Aggregate Audio Device Support

## Introduction

macOS Audio MIDI Setup allows users to create Aggregate Devices that combine multiple physical audio interfaces into a single virtual device. These devices use the transport type `kAudioDeviceTransportTypeAggregate`, which is the same transport type that AVAudioEngine uses for its internal private aggregate devices.

Wispr currently filters out all aggregate devices in `AudioEngine.availableInputDevices()` (line 59 of `AudioEngine.swift`). This was intended to hide AVAudioEngine's internal aggregate devices, but it also hides user-created aggregate devices from Audio MIDI Setup. Users who rely on aggregate devices for their audio setup cannot select them in Wispr.

## Glossary

- **Aggregate Device**: A virtual audio device created in macOS Audio MIDI Setup that combines multiple physical audio interfaces into one. It has input streams, a name, a UID, and a sample rate like any physical device.
- **Private Aggregate Device**: An aggregate device created internally by AVAudioEngine at runtime. These are implementation details and should not be user-visible.
- **Audio MIDI Setup**: The macOS system utility (`/Applications/Utilities/Audio MIDI Setup.app`) used to create and manage aggregate devices.

## Requirements

### Requirement 1: User-Created Aggregate Devices Appear in Device List

**User Story:** As a user who has created an aggregate device in Audio MIDI Setup, I want to see it in Wispr's input device list so I can use my preferred audio configuration for dictation.

#### Acceptance Criteria

1. WHEN `AudioEngine.availableInputDevices()` is called, IT SHALL include aggregate devices that were created by the user in Audio MIDI Setup.
2. User-created aggregate devices SHALL appear in the device selection UI alongside physical input devices.
3. User-created aggregate devices SHALL display their name and UID as configured in Audio MIDI Setup.
4. THE device list SHALL still exclude devices that have no input streams.

### Requirement 2: AVAudioEngine Private Aggregate Devices Remain Hidden

**User Story:** As a user, I do not want to see internal system-created aggregate devices in my device list, since they are implementation details of AVAudioEngine and selecting them could cause unexpected behavior.

#### Acceptance Criteria

1. Aggregate devices created internally by AVAudioEngine SHALL NOT appear in the device list returned by `availableInputDevices()`.
2. THE filtering logic SHALL distinguish between user-created and AVAudioEngine-created aggregate devices using a reliable heuristic (e.g., the device UID contains the `CADefaultDeviceAggregate` prefix, or the device is owned by a `com.apple.audio` process).
3. IF a new private aggregate device naming pattern is discovered in the future, THE heuristic SHALL be straightforward to update without architectural changes.

### Requirement 3: Audio Capture Works with Aggregate Devices

**User Story:** As a user, I want to record and transcribe audio through my aggregate device so I can use it for dictation just like any other input device.

#### Acceptance Criteria

1. WHEN a user-created aggregate device is selected, `AudioEngine.startCapture()` SHALL successfully start audio capture and return an `AsyncStream<Float>` of audio levels.
2. Audio captured from an aggregate device SHALL be converted to 16 kHz mono PCM Float32 format, matching the format required by the transcription engines.
3. Transcription of audio captured from an aggregate device SHALL produce results equivalent in quality to audio captured from a physical device.
4. IF an aggregate device becomes unavailable during capture (e.g., a sub-device is disconnected), THE capture SHALL fail with a descriptive `WisprError` rather than silently producing no audio.

### Requirement 4: Device Fallback Behavior with Aggregate Devices

**User Story:** As a user, I want Wispr to handle aggregate device availability changes gracefully, so my workflow is not disrupted if I disconnect a sub-device or remove the aggregate device.

#### Acceptance Criteria

1. IF the selected aggregate device is removed or becomes unavailable, Wispr SHALL fall back to the system default input device.
2. IF the selected aggregate device reappears (e.g., the user re-creates it or reconnects a sub-device), Wispr SHALL detect it via its persisted UID and re-select it automatically.
3. THE device change listener SHALL detect aggregate device addition and removal events the same way it detects physical device changes.
4. Wispr SHALL NOT crash or enter an unrecoverable state if an aggregate device disappears while it is the active input device.

### Requirement 5: Settings Persistence for Aggregate Devices

**User Story:** As a user, I want my selected aggregate device to be remembered across app launches so I do not have to re-select it every time I open Wispr.

#### Acceptance Criteria

1. WHEN the user selects an aggregate device, ITS UID SHALL be persisted in `SettingsStore` via the same mechanism used for physical devices.
2. ON app launch, IF the persisted device UID corresponds to an available aggregate device, Wispr SHALL automatically select that device.
3. ON app launch, IF the persisted device UID corresponds to an aggregate device that is not currently available, Wispr SHALL fall back to the system default input device without clearing the persisted UID.
4. THE persisted UID SHALL survive app updates and relaunches, consistent with existing device persistence behavior.
