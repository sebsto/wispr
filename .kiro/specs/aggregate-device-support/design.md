# Design Document: Aggregate Device Support

## Overview

The `availableInputDevices()` method in `AudioEngine` unconditionally filters out all aggregate devices (`kAudioDeviceTransportTypeAggregate`). This hides user-created aggregate devices from Audio MIDI Setup alongside AVAudioEngine's internal private aggregates. The fix distinguishes between these two categories using `kAudioAggregateDeviceIsPrivateKey` from the CoreAudio aggregate composition dictionary: private aggregates (created internally by AVAudioEngine) are filtered out, while user-created aggregates are shown in the device list.

The change is minimal — one new computed property on `CoreAudioDevice` and a single guard replacement in `availableInputDevices()`.

## Glossary

- **Aggregate Device**: A virtual CoreAudio device that combines multiple physical audio devices into one, created either by the user in Audio MIDI Setup or internally by system frameworks like AVAudioEngine
- **Audio MIDI Setup**: macOS utility (`/Applications/Utilities/Audio MIDI Setup.app`) that allows users to create and configure aggregate devices combining multiple audio interfaces
- **`kAudioDeviceTransportTypeAggregate`**: CoreAudio transport type constant identifying a device as an aggregate device
- **`kAudioAggregateDevicePropertyComposition`**: CoreAudio property selector that returns a `CFDictionary` describing the composition of an aggregate device, including its sub-devices and configuration flags
- **`kAudioAggregateDeviceIsPrivateKey` (`"priv"`)**: Key within the aggregate composition dictionary. When its value is `1`, the aggregate was created as a private/internal device (e.g., by AVAudioEngine for its own routing). When `0` or absent, the aggregate is user-created
- **Private Aggregate**: An aggregate device created internally by AVAudioEngine (or similar frameworks) to manage its audio graph routing. These are implementation details and should not appear in user-facing device lists
- **User Aggregate**: An aggregate device explicitly created by the user in Audio MIDI Setup to combine multiple audio interfaces (e.g., a USB mic + built-in speakers). These should appear as selectable input devices

## Details

### Problem

In `AudioEngine.availableInputDevices()`, the existing filter is:

```swift
guard device.transportType != kAudioDeviceTransportTypeAggregate else { return nil }
```

This blanket exclusion removes all aggregate devices. Users who create aggregate devices in Audio MIDI Setup (a common workflow for podcasters, musicians, and audio engineers who need to combine multiple interfaces) cannot select these devices in wispr.

### Why AVAudioEngine Creates Private Aggregates

AVAudioEngine internally creates aggregate devices to manage its audio graph when the input and output devices differ or when format bridging is needed. These aggregates appear in the system device list with names like `"CADefaultDeviceAggregate"`. They are marked as private in their composition dictionary and should never be shown to users.

### Solution: `isPrivateAggregate` Check

Instead of filtering by transport type alone, query the aggregate composition dictionary and check the `"priv"` key:

1. If the device is not an aggregate (`transportType != kAudioDeviceTransportTypeAggregate`), `isPrivateAggregate` returns `false` — the device passes through unaffected
2. If the device is an aggregate, query `kAudioAggregateDevicePropertyComposition` to get the composition `CFDictionary`
3. Cast to `[String: Any]` and check `composition["priv"] as? Int`
4. If `"priv"` is `1`, the aggregate is private (AVAudioEngine-internal) — filter it out
5. If `"priv"` is `0` or absent, the aggregate is user-created — allow it through

This is the proper CoreAudio API approach. Alternatives like name-matching (`"CADefault"` prefix) are fragile and undocumented.

## Implementation

### `CoreAudioDevice.isPrivateAggregate` (new computed property)

Added to the existing `CoreAudioDevice` struct in `AudioEngine.swift`:

```swift
nonisolated var isPrivateAggregate: Bool {
    guard transportType == kAudioDeviceTransportTypeAggregate else { return false }
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioAggregateDevicePropertyComposition,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
          size > 0 else { return false }
    var dict: CFDictionary?
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &dict) == noErr,
          let composition = dict as? [String: Any] else { return false }
    if let isPrivate = composition["priv"] as? Int, isPrivate == 1 {
        return true
    }
    return false
}
```

Key points:
- Early-returns `false` for non-aggregate devices (zero cost for the common case)
- Falls back to `false` (show the device) if the composition dictionary cannot be read — fail-open rather than hiding devices the user may need
- Uses `"priv"` string literal directly, which matches `kAudioAggregateDeviceIsPrivateKey`

### `availableInputDevices()` Filter Change

The guard statement changes from:

```swift
guard device.transportType != kAudioDeviceTransportTypeAggregate else { return nil }
```

To:

```swift
guard !device.isPrivateAggregate else { return nil }
```

### Sample Rate Considerations

Aggregate devices may report a different nominal sample rate than their constituent sub-devices. This is not a concern for wispr because:

- The tap is installed with `nil` format, which lets AVAudioEngine handle format negotiation with the hardware
- Audio is resampled to 16kHz mono Float32 for WhisperKit via the existing format converter
- The `nominalSampleRate` property on `CoreAudioDevice` already handles variable rates correctly

No changes are needed to `AudioUnitSetProperty` routing, format conversion, or tap setup.

### What Does NOT Change

- `startCapture()` flow — device routing via `kAudioOutputUnitProperty_CurrentDevice` works the same for aggregate devices as for physical devices
- Format conversion — the nil-format tap and lazy converter handle aggregate device formats
- Device disconnection fallback — aggregate devices disconnect like any other device
- `deviceIDForUID()` — UID lookup works identically for aggregate devices
- `setInputDevice()` — stores the `AudioDeviceID` regardless of device type

## Testing

### Manual Testing

1. Open Audio MIDI Setup, create an aggregate device combining the built-in mic with another input
2. Open wispr's device picker and verify the aggregate device appears in the list
3. Select the aggregate device and start a dictation — verify audio captures successfully
4. Verify AVAudioEngine's internal aggregates (e.g., `"CADefaultDeviceAggregate"`) do not appear

### Unit Tests

- **`isPrivateAggregate` returns `false` for non-aggregate devices**: Create a `CoreAudioDevice` wrapping the built-in mic and assert `isPrivateAggregate == false`
- **Private aggregates are filtered**: Mock or intercept the composition dictionary query to return `["priv": 1]` and verify the device is excluded from `availableInputDevices()`
- **User aggregates are included**: Mock the composition dictionary to return `["priv": 0]` (or no `"priv"` key) and verify the device appears in `availableInputDevices()`
- **Fail-open on query failure**: If `AudioObjectGetPropertyData` returns an error for the composition property, the device should still appear (not be hidden)

### Edge Cases

- Aggregate device with no input streams — already handled by the `hasInputStreams` guard
- Aggregate device with no name or UID — already handled by the `name`/`uid` optional binding
- Composition dictionary exists but `"priv"` key is missing — treated as non-private (shown)
- Composition dictionary exists but `"priv"` value is not an `Int` — treated as non-private (shown)
