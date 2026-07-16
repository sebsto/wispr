//
//  AudioInputActivityMonitor.swift
//  wispr
//
//  Low-level CoreAudio monitor that reports when the system's default audio
//  input device starts or stops being used by *any* process.
//
//  Used by MeetingDetectionService to detect when a meeting begins (a
//  conferencing app starts using the microphone) without maintaining a list of
//  known applications.
//

import CoreAudio
import Foundation
import WisprCore
import os

/// Abstraction over "the default input device is / is not in use", so the
/// coordinating service can be unit-tested with a fake.
protocol InputActivityMonitoring: AnyObject, Sendable {
    /// Starts observing input-device activity.
    ///
    /// The `onChange` closure is invoked whenever the "in use" state changes,
    /// and once immediately with the current state to establish a baseline.
    /// It may be called on an arbitrary queue.
    nonisolated func start(onChange: @escaping @Sendable (Bool) -> Void)

    /// Stops observing and releases all CoreAudio listeners.
    nonisolated func stop()
}

/// Observes `kAudioDevicePropertyDeviceIsRunningSomewhere` on the current
/// default input device.
///
/// **Concurrency:** every CoreAudio call and all mutable state are confined to
/// a single private serial queue. CoreAudio listener blocks are registered
/// against that same queue, so they never run concurrently with `start` /
/// `stop` work. The type is `@unchecked Sendable` because this confinement is a
/// runtime discipline the compiler cannot prove.
nonisolated final class AudioInputActivityMonitor: InputActivityMonitoring, @unchecked Sendable {

    private let queue = DispatchQueue(label: "com.stormacq.mac.wispr.meeting-detection")

    /// The input device currently being observed.
    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    /// Listener on the observed device's running-somewhere property.
    private var runningListenerBlock: AudioObjectPropertyListenerBlock?

    /// Listener on the system object's default-input-device property.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Consumer callback; only read/written on `queue`.
    private var onChange: (@Sendable (Bool) -> Void)?

    // MARK: - InputActivityMonitoring

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        queue.async {
            self.onChange = onChange
            self.attachDefaultDeviceChangeListener()
            self.attachToDefaultInput()
            // Emit the current state so the consumer has a baseline and does not
            // treat an already-in-use device as a fresh rising edge.
            onChange(Self.readIsRunning(self.deviceID))
        }
    }

    func stop() {
        queue.sync {
            self.detachRunningListener()
            self.detachDefaultDeviceChangeListener()
            self.onChange = nil
            self.deviceID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Listener Management (all on `queue`)

    private func attachToDefaultInput() {
        let device = Self.defaultInputDevice()
        guard device != AudioObjectID(kAudioObjectUnknown) else {
            Log.audioEngine.warning("AudioInputActivityMonitor — no default input device")
            return
        }
        deviceID = device

        var address = Self.runningAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            self.onChange?(Self.readIsRunning(self.deviceID))
        }
        let status = AudioObjectAddPropertyListenerBlock(device, &address, queue, block)
        if status == noErr {
            runningListenerBlock = block
        } else {
            Log.audioEngine.error(
                "AudioInputActivityMonitor — failed to add running listener (status \(status))")
        }
    }

    private func detachRunningListener() {
        guard let block = runningListenerBlock,
            deviceID != AudioObjectID(kAudioObjectUnknown)
        else { return }
        var address = Self.runningAddress()
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, block)
        runningListenerBlock = nil
    }

    private func attachDefaultDeviceChangeListener() {
        var address = Self.defaultInputAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            // Default input device changed — move the running listener to it.
            self.detachRunningListener()
            self.attachToDefaultInput()
            self.onChange?(Self.readIsRunning(self.deviceID))
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        if status == noErr {
            defaultDeviceListenerBlock = block
        } else {
            Log.audioEngine.error(
                "AudioInputActivityMonitor — failed to add default-device listener (status \(status))"
            )
        }
    }

    private func detachDefaultDeviceChangeListener() {
        guard let block = defaultDeviceListenerBlock else { return }
        var address = Self.defaultInputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, block)
        defaultDeviceListenerBlock = nil
    }

    // MARK: - CoreAudio Helpers

    /// Fresh property address for the default input device on the system object.
    private static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Fresh property address for a device's "is running somewhere" flag.
    private static func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Resolves the current default input device, or `kAudioObjectUnknown`.
    private static func defaultInputDevice() -> AudioObjectID {
        var address = defaultInputAddress()
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    /// Reads whether `device` is currently in use by any process.
    private static func readIsRunning(_ device: AudioObjectID) -> Bool {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        var address = runningAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
