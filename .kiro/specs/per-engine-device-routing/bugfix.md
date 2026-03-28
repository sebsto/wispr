# Bugfix Requirements Document

## Introduction

The `AudioEngine.startCapture()` method changes the system-wide default input device via `AudioObjectSetPropertyData` with `kAudioHardwarePropertyDefaultInputDevice` when a user selects a specific audio input device. This is a global side effect that affects all other applications on the system. The previous per-engine approach using `kAudioOutputUnitProperty_CurrentDevice` on the AVAudioEngine's input node AudioUnit was replaced in PR #40 because it failed for Bluetooth devices (AirPods) in sandboxed apps. The fix must restore per-engine device routing without the global side effect, while handling Bluetooth/sandbox edge cases.

## Bug Analysis

### Current Behavior (Defect)

1.1 WHEN a user selects a specific audio input device and starts capture THEN the system changes the macOS system-wide default input device via `AudioObjectSetPropertyData`, affecting all other applications that use the default input device

1.2 WHEN capture ends (stopCapture or cancelCapture) THEN the system does NOT restore the previous system default input device, leaving the global default permanently changed to the device selected by wispr

1.3 WHEN a user selects a Bluetooth device (e.g., AirPods) and starts capture THEN the system changes the global default and polls for up to 3 seconds waiting for the system default to switch, introducing unnecessary latency caused by the global-default approach

### Expected Behavior (Correct)

2.1 WHEN a user selects a specific audio input device and starts capture THEN the system SHALL route audio input to that device using `kAudioOutputUnitProperty_CurrentDevice` on the AVAudioEngine's input node AudioUnit, without modifying the system-wide default input device

2.2 WHEN capture ends (stopCapture or cancelCapture) THEN the system SHALL leave the macOS system-wide default input device unchanged from what it was before capture started

2.3 WHEN a user selects a Bluetooth device (e.g., AirPods) and starts capture THEN the system SHALL set the device on the AudioUnit via `kAudioOutputUnitProperty_CurrentDevice` BEFORE reading the input node format or installing taps, allowing the Bluetooth profile switch (A2DP → HFP/SCO) to occur naturally through the AudioUnit pipeline

### Runtime Device Switching

2.4 WHEN a user changes the selected audio input device in Settings while the application is running THEN the system SHALL use the newly selected device on the next recording session without requiring an application relaunch

2.5 WHEN a user changes the selected audio input device in Settings between two consecutive recording sessions THEN the system SHALL read the current device preference from `SettingsStore.selectedAudioDeviceUID` at the start of each recording session and resolve it to the corresponding `AudioDeviceID`, ensuring the correct device is always used

2.6 WHEN a user switches from device A to device B in Settings and starts a new recording THEN the AudioEngine SHALL apply `kAudioOutputUnitProperty_CurrentDevice` with device B's AudioDeviceID on the freshly created AVAudioEngine instance, with no stale references to device A

### Unchanged Behavior (Regression Prevention)

3.1 WHEN no specific device is selected (system default) and capture starts THEN the system SHALL CONTINUE TO use the system default input device via AVAudioEngine's default behavior

3.2 WHEN capture is started with a selected device THEN the system SHALL install the tap with an explicit format matching the device's actual hardware rate (queried via `kAudioDevicePropertyNominalSampleRate`) to avoid stale cached formats after Bluetooth profile switches; WHEN capture is started with the system default device THEN the system SHALL install the tap with nil format. In both cases, the lazy converter SHALL be retained to handle any remaining format drift.

3.3 WHEN audio is captured THEN the system SHALL CONTINUE TO resample to 16kHz mono Float32 format for WhisperKit compatibility

3.4 WHEN a device is disconnected during capture THEN the system SHALL CONTINUE TO fall back to the system default input device and notify the user

3.5 WHEN capture is active THEN the system SHALL CONTINUE TO prevent concurrent capture sessions

3.6 WHEN capture is stopped THEN the system SHALL CONTINUE TO return the recorded audio samples and clean up resources immediately
