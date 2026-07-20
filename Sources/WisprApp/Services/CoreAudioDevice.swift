//
//  CoreAudioDevice.swift
//  wispr
//
//  Lightweight, idiomatic wrapper around an AudioDeviceID plus the shared
//  system-object queries (default input device resolution). Used by both
//  AudioEngine (capture) and AudioInputActivityMonitor (meeting detection) so
//  the CoreAudio boilerplate lives in one place.
//

import CoreAudio
import Foundation

/// Lightweight wrapper around an `AudioDeviceID` that provides idiomatic
/// property access. `nonisolated` and `Sendable` so it can be used from any
/// isolation domain (actors, `@MainActor`, CoreAudio callback threads).
nonisolated struct CoreAudioDevice: Sendable {
    let id: AudioDeviceID

    // MARK: - System Object Queries

    /// The system's current default input device, or `nil` if none is set.
    static var defaultInput: CoreAudioDevice? {
        guard let id = defaultInputDeviceID() else { return nil }
        return CoreAudioDevice(id: id)
    }

    /// Resolves the current default input `AudioDeviceID`, or `nil`.
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    // MARK: - Device Properties

    /// Whether this device is currently in use ("running") by any process.
    var isRunningSomewhere: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }

    var hasInputStreams: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }

    var name: String? {
        getStringProperty(kAudioObjectPropertyName)
    }

    var uid: String? {
        getStringProperty(kAudioDevicePropertyDeviceUID)
    }

    /// Whether this aggregate device is marked as private (created internally by AVAudioEngine).
    /// User-created aggregates from Audio MIDI Setup are not private.
    var isPrivateAggregate: Bool {
        guard transportType == kAudioDeviceTransportTypeAggregate else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }
        var dict: CFDictionary?
        let status = withUnsafeMutablePointer(to: &dict) { ptr in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
        }
        guard status == noErr,
            let composition = dict as? [String: Any]
        else { return false }
        // kAudioAggregateDeviceIsPrivateKey == "priv"
        if let isPrivate = composition["priv"] as? Int, isPrivate == 1 {
            return true
        }
        return false
    }

    /// The transport type of the device (USB, Bluetooth, Built-In, etc.)
    var transportType: UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    /// The device's current nominal sample rate as reported by CoreAudio.
    var nominalSampleRate: Double? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    /// Number of input channels on this device.
    var inputChannelCount: UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferListPointer) == noErr
        else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + $1.mNumberChannels }
    }

    private func getStringProperty(_ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>>.size)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        guard status == noErr else { return nil }
        return value?.takeUnretainedValue() as String?
    }
}
