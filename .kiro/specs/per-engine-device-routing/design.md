# Per-Engine Device Routing Bugfix Design

## Overview

The `AudioEngine.startCapture()` method currently changes the macOS system-wide default input device when a user selects a specific audio input device. This is a global side effect that affects every other application on the system. The fix replaces this approach with per-AudioUnit device selection using `kAudioOutputUnitProperty_CurrentDevice` on the AVAudioEngine's `inputNode.audioUnit`, which scopes the device choice to this engine instance only. The `setDefaultInputDevice()` helper and the polling loop are removed entirely.

## Glossary

- **Bug_Condition (C)**: The condition that triggers the bug — when `startCapture()` is called with a non-nil `selectedDeviceID`, the code calls `setDefaultInputDevice()` which mutates the system-wide default
- **Property (P)**: The desired behavior — audio is routed to the selected device via `kAudioOutputUnitProperty_CurrentDevice` on the AudioUnit, with no system-wide side effect
- **Preservation**: Existing behaviors that must remain unchanged — nil-format tap with lazy converter, 16kHz resampling, device fallback, concurrent-capture guard, stop/cancel lifecycle
- **`kAudioOutputUnitProperty_CurrentDevice`**: A Core Audio property (selector `0x63646576` / `'cdev'`) set on an AudioUnit to route that unit's I/O to a specific `AudioDeviceID` without changing the system default
- **`AudioObjectSetPropertyData` (system default)**: The Core Audio call currently used to change the global default input device — this is the call being removed
- **HAL proxy**: The Core Audio Hardware Abstraction Layer process that brokers device I/O; Bluetooth devices may need a brief initialization window after the AudioUnit property is set
- **A2DP → HFP/SCO**: Bluetooth profile switch from high-quality playback-only (A2DP) to bidirectional headset profile (HFP/SCO) that enables the microphone

## Bug Details

### Bug Condition

The bug manifests when `startCapture()` is called with a non-nil `selectedDeviceID`. The current code calls `setDefaultInputDevice()` via `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`, which changes the system-wide default input device. This affects all other applications. Additionally, a polling loop waits up to 3 seconds for the system default to switch, adding unnecessary latency.

**Formal Specification:**
```
FUNCTION isBugCondition(input)
  INPUT: input of type StartCaptureCall
  OUTPUT: boolean

  RETURN input.selectedDeviceID != nil
         AND input.selectedDeviceID != getDefaultInputDeviceID()
END FUNCTION
```

When `isBugCondition` is true, the current code executes `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`, which is the defect.

### Examples

- User selects "AirPods Pro" (deviceID=42) while built-in mic (deviceID=67) is system default → current code changes system default to 42, all apps now use AirPods input. Expected: only wispr's AudioEngine uses AirPods, system default stays at 67.
- User selects external USB mic (deviceID=88) → current code changes system default to 88, Zoom/FaceTime/etc. switch to USB mic. Expected: only wispr uses USB mic.
- User selects a Bluetooth headset → current code changes system default and polls for up to 3s. Expected: `kAudioOutputUnitProperty_CurrentDevice` is set on the AudioUnit, profile switch happens naturally, no polling needed.
- User has no specific device selected (system default) → current code skips `setDefaultInputDevice()`. Expected: same behavior, no change needed.

## Expected Behavior

### Preservation Requirements

**Unchanged Behaviors:**
- When no specific device is selected (`selectedDeviceID == nil`), AVAudioEngine uses the system default input device via its default behavior
- The tap is installed with `nil` format (lazy converter creation) to handle hardware format changes during device switches
- Audio is resampled to 16kHz mono Float32 for WhisperKit compatibility
- Device disconnection during capture falls back to the system default and notifies the user
- Concurrent capture sessions are prevented (`isCapturing` guard)
- `stopCapture()` returns recorded samples and cleans up; `cancelCapture()` discards and cleans up
- The `availableInputDevices()`, `deviceIDForUID()`, and `setInputDevice()` public API signatures remain unchanged

**Scope:**
All inputs where `selectedDeviceID` is nil (system default path) should be completely unaffected by this fix. This includes:
- Default device capture sessions
- Device enumeration
- Stop/cancel lifecycle
- Audio level streaming and raw audio chunk streaming

## Hypothesized Root Cause

Based on the bug description and code analysis, the root cause is clear:

1. **Intentional but incorrect design choice**: The comment in `startCapture()` (lines ~75-85) explicitly states that `kAudioOutputUnitProperty_CurrentDevice` "does not work for Bluetooth devices in sandboxed apps" and that changing the system default is "the reliable path." This was a deliberate workaround, but it introduces a global side effect.

2. **Missing per-AudioUnit device assignment**: The code never calls `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice` on `inputNode.audioUnit`. Instead, it relies on AVAudioEngine picking up the system default after it's been changed.

3. **Unnecessary polling loop**: The 3-second polling loop (`while ContinuousClock.now < deadline`) exists only because the system-default approach requires waiting for the OS to propagate the change. With per-AudioUnit routing, this is unnecessary.

4. **Bluetooth concern may be outdated**: The original failure with `kAudioOutputUnitProperty_CurrentDevice` for Bluetooth devices may have been caused by setting the property AFTER reading the input node format or installing taps. Setting it BEFORE these operations (and using the nil-format tap) should handle the A2DP → HFP/SCO switch naturally.

## Correctness Properties

Property 1: Bug Condition - Per-Engine Device Routing

_For any_ `startCapture()` call where `selectedDeviceID` is non-nil and differs from the current system default, the fixed `startCapture()` SHALL route audio through the selected device using `kAudioOutputUnitProperty_CurrentDevice` on `inputNode.audioUnit` WITHOUT calling `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`, and the system-wide default input device SHALL remain unchanged.

**Validates: Requirements 2.1, 2.2**

Property 2: Preservation - Default Device and Lifecycle Behavior

_For any_ `startCapture()` call where `selectedDeviceID` is nil (system default), and for all `stopCapture()` / `cancelCapture()` calls, the fixed code SHALL produce exactly the same behavior as the original code, preserving default-device routing, nil-format tap installation, 16kHz resampling, concurrent-capture prevention, and resource cleanup.

**Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5, 3.6**

Property 3: Runtime Device Switching - Fresh Device Resolution Per Session

_For any_ sequence of recording sessions where the user changes `settingsStore.selectedAudioDeviceUID` between sessions, each `startCapture()` call SHALL use the device corresponding to the current setting at call time. The `AudioEngine` SHALL NOT cache or reuse a stale `AudioDeviceID` from a previous session. Each session creates a new `AVAudioEngine` instance and applies `kAudioOutputUnitProperty_CurrentDevice` with the freshly resolved device ID.

**Validates: Requirements 2.4, 2.5, 2.6**

## Fix Implementation

### Changes Required

Assuming our root cause analysis is correct:

**File**: `wispr/Services/AudioEngine.swift`

**Function**: `startCapture()`

**Specific Changes**:

1. **Remove system-default mutation block**: Delete the entire block that calls `setDefaultInputDevice()`, including the polling loop (approximately lines 82-112 in the current code). This removes the global side effect.

2. **Add per-AudioUnit device assignment**: After creating the `AVAudioEngine` and before accessing `inputNode` format or installing taps, set `kAudioOutputUnitProperty_CurrentDevice` on `inputNode.audioUnit`:
   ```swift
   if let deviceID = selectedDeviceID {
       var devID = deviceID
       let status = AudioUnitSetProperty(
           inputNode.audioUnit!,
           kAudioOutputUnitProperty_CurrentDevice,
           kAudioUnitScope_Global,
           0,
           &devID,
           UInt32(MemoryLayout<AudioDeviceID>.size)
       )
       if status != noErr {
           // retry once for Bluetooth HAL proxy initialization
           try await Task.sleep(for: .milliseconds(250))
           let retryStatus = AudioUnitSetProperty(...)
           if retryStatus != noErr {
               Log.audioEngine.warning("Failed to set per-engine device \(deviceID), falling back to system default")
               selectedDeviceID = nil
           }
       }
   }
   ```

3. **Set device BEFORE format/tap access**: The `kAudioOutputUnitProperty_CurrentDevice` call must happen before `inputNode.installTap(...)` and before any read of `inputNode.outputFormat(forBus:)`. This ensures the AudioUnit knows which device to use when the tap queries the hardware format.

4. **Add Bluetooth retry**: If `AudioUnitSetProperty` fails with an error, wait 250ms and retry once. This handles the case where the Bluetooth HAL proxy needs a moment to initialize after the A2DP → HFP/SCO profile switch.

5. **Remove `setDefaultInputDevice()` method**: Delete the private `setDefaultInputDevice(_ deviceID:)` method entirely, as it is no longer called.

6. **Remove polling infrastructure**: The `ContinuousClock` deadline and polling `while` loop are removed along with the system-default block.

7. **Runtime device switching — no stale state**: The existing architecture already supports runtime device switching: `StateManager.beginRecording()` reads `settingsStore.selectedAudioDeviceUID` fresh on every recording start and calls `audioEngine.setInputDevice(deviceID)` before `startCapture()`. The `AudioEngine.setInputDevice()` method stores the `selectedDeviceID`, and `startCapture()` creates a brand-new `AVAudioEngine` instance each time (the previous one is torn down in `stopCapture()` / `cancelCapture()`). This means each session gets a fresh AudioUnit with the correct device applied via `kAudioOutputUnitProperty_CurrentDevice`. No additional changes are needed to support runtime device switching — the per-session engine creation pattern inherently prevents stale device references. The key invariant is: `teardownEngine()` sets `self.engine = nil`, and `startCapture()` always creates `let audioEngine = AVAudioEngine()` — there is no engine reuse across sessions.

**File**: `wisprTests/AudioEngineTests.swift`

**Test Changes**:
- Add a test verifying that `startCapture()` with a selected device does not change the system default input device
- Add a test verifying the retry path when `AudioUnitSetProperty` fails initially

## Testing Strategy

### Validation Approach

The testing strategy follows a two-phase approach: first, surface counterexamples that demonstrate the bug on unfixed code, then verify the fix works correctly and preserves existing behavior.

### Exploratory Bug Condition Checking

**Goal**: Surface counterexamples that demonstrate the bug BEFORE implementing the fix. Confirm or refute the root cause analysis.

**Test Plan**: Write tests that check whether the system default input device changes after `startCapture()` is called with a selected device. Run these on the UNFIXED code to observe the global side effect.

**Test Cases**:
1. **System Default Mutation Test**: Record the system default input device ID, call `startCapture()` with a different selected device, then check if the system default changed (will fail on unfixed code — the default WILL change)
2. **Polling Latency Test**: Measure the time `startCapture()` takes when selecting a Bluetooth device — the 3-second polling loop should be observable (will be slow on unfixed code)
3. **No Device Selected Test**: Call `startCapture()` with no selected device and verify the system default is unchanged (should pass on both unfixed and fixed code)

**Expected Counterexamples**:
- System default input device changes to the selected device after `startCapture()`
- `startCapture()` takes up to 3 seconds when selecting a device that differs from the current default

### Fix Checking

**Goal**: Verify that for all inputs where the bug condition holds, the fixed function produces the expected behavior.

**Pseudocode:**
```
FOR ALL input WHERE isBugCondition(input) DO
  defaultBefore := getDefaultInputDeviceID()
  result := startCapture_fixed(input)
  defaultAfter := getDefaultInputDeviceID()
  ASSERT defaultBefore == defaultAfter  // system default unchanged
  ASSERT audioEngine.isCapturing == true  // capture started successfully
END FOR
```

### Preservation Checking

**Goal**: Verify that for all inputs where the bug condition does NOT hold, the fixed function produces the same result as the original function.

**Pseudocode:**
```
FOR ALL input WHERE NOT isBugCondition(input) DO
  ASSERT startCapture_original(input) = startCapture_fixed(input)
END FOR
```

**Testing Approach**: Property-based testing is recommended for preservation checking because:
- It generates many test cases automatically across the input domain
- It catches edge cases that manual unit tests might miss
- It provides strong guarantees that behavior is unchanged for all non-buggy inputs

**Test Plan**: Observe behavior on UNFIXED code first for default-device capture, stop/cancel lifecycle, and device enumeration, then write property-based tests capturing that behavior.

**Test Cases**:
1. **Default Device Preservation**: Verify that `startCapture()` with no selected device continues to use the system default and produces audio level streams
2. **Stop/Cancel Lifecycle Preservation**: Verify that `stopCapture()` returns samples and `cancelCapture()` discards them, with proper cleanup in both cases
3. **Concurrent Capture Prevention**: Verify that calling `startCapture()` twice throws `WisprError.audioRecordingFailed("Already capturing")`
4. **Device Enumeration Preservation**: Verify that `availableInputDevices()` and `deviceIDForUID()` return the same results before and after the fix

### Unit Tests

- Test that `startCapture()` with a selected device does not call `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`
- Test that `startCapture()` with a selected device calls `AudioUnitSetProperty` with `kAudioOutputUnitProperty_CurrentDevice`
- Test the retry path: first `AudioUnitSetProperty` call fails, second succeeds after 250ms delay
- Test the fallback path: both `AudioUnitSetProperty` calls fail, `selectedDeviceID` is set to nil and capture proceeds with system default
- Test that `setDefaultInputDevice()` method no longer exists (compile-time verification)

### Property-Based Tests

- Generate random `AudioDeviceID` values (valid and invalid) and verify the system default is never changed by `startCapture()`
- Generate random sequences of `startCapture` / `stopCapture` / `cancelCapture` calls and verify resource cleanup is consistent
- Generate random device selection scenarios (nil, valid device, invalid device) and verify capture always either succeeds or throws a meaningful error

### Integration Tests

- Full capture flow with a specific device selected: set device → start capture → verify audio levels → stop capture → verify samples returned → verify system default unchanged
- Device switch during idle: set device A → start/stop → set device B → start/stop → verify both sessions captured correctly
- Runtime device switching: change `selectedAudioDeviceUID` in settings between two recording sessions → verify each session uses the correct device and no stale AudioDeviceID is carried over
- Bluetooth device simulation: set a Bluetooth device → start capture → verify the nil-format tap handles the HFP/SCO format correctly
