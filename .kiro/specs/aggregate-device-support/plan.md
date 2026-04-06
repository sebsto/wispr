# Aggregate Device Support — Initial Analysis

## Problem

Wispr's `AudioEngine.swift` (line 59) blanket-filters all aggregate devices:

```swift
guard device.transportType != kAudioDeviceTransportTypeAggregate else { return nil }
```

This was intended to hide AVAudioEngine's internal private aggregate devices, but it also hides **user-created aggregate devices** from Audio MIDI Setup.

## What Apple's Article Describes

An **Aggregate Device** is a virtual audio device created in macOS Audio MIDI Setup that combines multiple physical interfaces into one. Its CoreAudio transport type is `kAudioDeviceTransportTypeAggregate`. It appears like any other device — it has input streams, a name, a UID, and a sample rate.

Reference: https://support.apple.com/en-us/102171

## Why It's Filtered Out

The guard on line 59 removes every device with transport type `Aggregate`. The comment says "Filter out aggregate devices created by AVAudioEngine internally" — but there's no distinction being made between:

1. **AVAudioEngine's private aggregate devices** — auto-created, typically named something like `CADefaultDeviceAggregate`, should be hidden
2. **User-created aggregate devices** — created in Audio MIDI Setup, have real names like "My USB Combo", should be shown

## Can Wispr Use Aggregate Devices?

**Yes, absolutely.** Aggregate devices are fully functional CoreAudio devices with input streams. `AVAudioEngine` and `AudioUnitSetProperty` work fine with them. The only concern is sample rate — an aggregate device's nominal sample rate depends on its clock source, but the existing code already handles variable sample rates via the lazy converter in the tap callback.

## Considered Approaches

### Option A — Name-based heuristic

AVAudioEngine's private aggregates typically have names containing `"CADefaultDeviceAggregate"` or similar system-generated patterns. Allow aggregate devices whose name doesn't match these patterns.

- Simple
- Fragile — Apple could change naming conventions

### Option B — Private flag check (recommended)

Query `kAudioAggregateDevicePropertyComposition` on aggregate devices and check `kAudioAggregateDeviceIsPrivateKey` (`"priv"`). AVAudioEngine's auto-created aggregates are marked as private (`"priv": 1`). User-created ones from Audio MIDI Setup are not.

- Robust — uses the documented CoreAudio API
- No dependency on naming conventions

## No Other Blockers

The rest of the pipeline requires no changes:

- **Device routing** via `AudioUnitSetProperty` works with aggregate devices
- **Format detection** via lazy converter in the tap callback handles variable sample rates
- **`hasInputStreams` check** (line 60) already ensures only devices with input capability are shown
- **Settings persistence** stores device UID, which aggregate devices have
- **Device fallback** logic is device-type agnostic

## Conclusion

The change is isolated to the filter logic in `availableInputDevices()`: add an `isPrivateAggregate` property to `CoreAudioDevice` and replace the blanket guard with a private-only check.
