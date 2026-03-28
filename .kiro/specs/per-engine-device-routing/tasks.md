# Implementation Plan

- [x] 1. Write bug condition exploration test
  - **Property 1: Bug Condition** - System Default Mutation on Per-Device Capture
  - **CRITICAL**: This test MUST FAIL on unfixed code — failure confirms the bug exists
  - **DO NOT attempt to fix the test or the code when it fails**
  - **NOTE**: This test encodes the expected behavior — it will validate the fix when it passes after implementation
  - **GOAL**: Surface counterexamples that demonstrate the system-wide default input device is mutated when `startCapture()` is called with a non-nil `selectedDeviceID`
  - **Scoped PBT Approach**: Scope the property to concrete failing cases — call `startCapture()` with a `selectedDeviceID` that differs from the current system default, then assert the system default is unchanged
  - **File**: `wisprTests/AudioEngineTests.swift`
  - **Bug Condition from design**: `isBugCondition(input) = input.selectedDeviceID != nil AND input.selectedDeviceID != getDefaultInputDeviceID()`
  - **Test implementation**:
    - Record the system default input device ID before calling `startCapture()`
    - Call `setInputDevice(deviceID)` with a device that differs from the current system default
    - Call `startCapture()`
    - Assert the system default input device ID has NOT changed (i.e., `defaultBefore == defaultAfter`)
    - Assert capture started successfully (stream returned without error)
    - Clean up with `cancelCapture()`
  - **Expected Behavior assertion**: `startCapture()` routes audio via `kAudioOutputUnitProperty_CurrentDevice` on `inputNode.audioUnit` without calling `AudioObjectSetPropertyData` on `kAudioHardwarePropertyDefaultInputDevice`
  - Run test on UNFIXED code — expect FAILURE (system default WILL change, confirming the bug)
  - Document counterexamples found (e.g., "system default changed from deviceID 67 to deviceID 42 after startCapture()")
  - Mark task complete when test is written, run, and failure is documented
  - _Requirements: 1.1, 2.1, 2.2_

- [x] 2. Write preservation property tests (BEFORE implementing fix)
  - **Property 2: Preservation** - Default Device Path and Lifecycle Behavior
  - **IMPORTANT**: Follow observation-first methodology — run UNFIXED code with non-buggy inputs first
  - **File**: `wisprTests/AudioEngineTests.swift`
  - **Non-bug condition**: `selectedDeviceID == nil` (system default path), plus stop/cancel lifecycle and concurrent-capture guard
  - **Observation-first steps**:
    - Observe: `startCapture()` with no selected device uses system default, returns an `AsyncStream<Float>`, system default is unchanged
    - Observe: `stopCapture()` returns `[Float]` samples and cleans up (engine is nil, isCapturing is false)
    - Observe: `cancelCapture()` discards buffer and cleans up identically
    - Observe: calling `startCapture()` twice throws `WisprError.audioRecordingFailed("Already capturing")`
    - Observe: `availableInputDevices()` returns consistent device list with unique UIDs
    - Observe: `deviceIDForUID(knownUID)` returns the correct `AudioDeviceID`
  - **Property-based tests to write**:
    - For all calls where `selectedDeviceID` is nil: `startCapture()` succeeds, system default is unchanged, audio level stream yields values in [0.0, 1.0]
    - For all stop/cancel sequences: resources are cleaned up (no engine leak), subsequent `startCapture()` succeeds
    - For concurrent capture attempts: always throws "Already capturing" error
    - For device enumeration: `availableInputDevices()` returns devices with non-empty name/uid and unique UIDs
  - Verify all tests PASS on UNFIXED code (confirms baseline behavior to preserve)
  - Mark task complete when tests are written, run, and passing on unfixed code
  - _Requirements: 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

- [x] 3. Fix per-engine device routing in AudioEngine.startCapture()

  - [x] 3.1 Remove system-default mutation and add per-AudioUnit device assignment
    - **File**: `wispr/Services/AudioEngine.swift`, function `startCapture()`
    - Delete the entire system-default-changing block (the `if let deviceID = selectedDeviceID` block that calls `setDefaultInputDevice()`, including the polling loop and all associated comments — approximately lines 82–112)
    - Delete the `setDefaultInputDevice(_ deviceID:)` private method entirely (it is no longer called anywhere)
    - Keep `getDefaultInputDeviceID()` — it is still used by `handleDeviceDisconnection()`
    - After `let audioEngine = AVAudioEngine()` and `let inputNode = audioEngine.inputNode`, add per-AudioUnit device assignment BEFORE installing taps or reading format:
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
              // Single retry for Bluetooth HAL proxy initialization
              try await Task.sleep(for: .milliseconds(250))
              var retryDevID = deviceID
              let retryStatus = AudioUnitSetProperty(
                  inputNode.audioUnit!,
                  kAudioOutputUnitProperty_CurrentDevice,
                  kAudioUnitScope_Global,
                  0,
                  &retryDevID,
                  UInt32(MemoryLayout<AudioDeviceID>.size)
              )
              if retryStatus != noErr {
                  Log.audioEngine.warning("Failed to set per-engine device \(deviceID) (OSStatus: \(retryStatus)), falling back to system default")
                  selectedDeviceID = nil
              }
          }
          if selectedDeviceID != nil {
              Log.audioEngine.debug("Per-engine input device set to \(deviceID)")
          }
      }
      ```
    - The `kAudioOutputUnitProperty_CurrentDevice` call MUST happen before `inputNode.installTap(...)` and before any read of `inputNode.outputFormat(forBus:)` — this ensures the AudioUnit knows which device to use when the tap queries the hardware format
    - **Implementation note**: The 250ms single-retry from the design spec was intentionally replaced with a simpler fail-and-fallback approach. The `waitForBluetoothHFP()` polling (up to 3s) handles the Bluetooth HAL proxy timing concern more robustly than a single retry, making the retry redundant.
    - Keep the nil-format tap approach (lazy converter) unchanged — it handles format changes from Bluetooth profile switches
    - _Bug_Condition: isBugCondition(input) where input.selectedDeviceID != nil AND input.selectedDeviceID != getDefaultInputDeviceID()_
    - _Expected_Behavior: Audio routed via kAudioOutputUnitProperty_CurrentDevice on inputNode.audioUnit, system default unchanged_
    - _Preservation: nil-format tap, 16kHz resampling, concurrent-capture guard, stop/cancel lifecycle, device enumeration all unchanged_
    - _Requirements: 1.1, 1.2, 1.3, 2.1, 2.2, 2.3, 3.1, 3.2, 3.3, 3.4, 3.5, 3.6_

  - [x] 3.2 Verify bug condition exploration test now passes
    - **Property 1: Expected Behavior** - System Default Unchanged After Per-Device Capture
    - **IMPORTANT**: Re-run the SAME test from task 1 — do NOT write a new test
    - The test from task 1 encodes the expected behavior: system default is unchanged after `startCapture()` with a selected device
    - When this test passes, it confirms the expected behavior is satisfied
    - Run bug condition exploration test from step 1
    - **EXPECTED OUTCOME**: Test PASSES (confirms bug is fixed — system default is no longer mutated)
    - _Requirements: 2.1, 2.2_

  - [x] 3.3 Verify preservation tests still pass
    - **Property 2: Preservation** - Default Device Path and Lifecycle Behavior
    - **IMPORTANT**: Re-run the SAME tests from task 2 — do NOT write new tests
    - Run preservation property tests from step 2
    - **EXPECTED OUTCOME**: Tests PASS (confirms no regressions in default-device path, stop/cancel lifecycle, concurrent-capture guard, device enumeration)
    - Confirm all tests still pass after fix (no regressions)

- [x] 4. Checkpoint — Ensure all tests pass
  - Run the full test suite (`wisprTests/AudioEngineTests.swift`) and confirm all tests pass
  - Verify no regressions in other test files that may exercise AudioEngine indirectly
  - Ensure all tests pass, ask the user if questions arise
