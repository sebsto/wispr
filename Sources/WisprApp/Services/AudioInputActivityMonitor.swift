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
protocol InputActivityMonitoring: Sendable {
    /// Starts observing input-device activity.
    ///
    /// The `onChange` closure is invoked whenever the "in use" state changes,
    /// and once immediately with the current state to establish a baseline.
    /// It may be called from an arbitrary isolation context.
    func start(onChange: @escaping @Sendable (Bool) -> Void) async

    /// Stops observing and releases all CoreAudio listeners.
    func stop() async
}

/// Observes `kAudioDevicePropertyDeviceIsRunningSomewhere` on the current
/// default input device.
///
/// **Concurrency:** all mutable state and every CoreAudio registration call are
/// isolated to this `actor`, so the compiler guarantees they never race.
/// CoreAudio delivers listener callbacks on an unspecified HAL thread (we pass
/// no dispatch queue); each callback immediately hops back onto the actor with
/// a `Task`, so state is only ever touched inside the actor's isolation domain.
actor AudioInputActivityMonitor: InputActivityMonitoring {

    /// The input device currently being observed.
    private var deviceID = AudioObjectID(kAudioObjectUnknown)

    /// Listener on the observed device's running-somewhere property.
    private var runningListenerBlock: AudioObjectPropertyListenerBlock?

    /// Listener on the system object's default-input-device property.
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?

    /// Consumer callback; only read/written inside the actor.
    private var onChange: (@Sendable (Bool) -> Void)?

    // MARK: - InputActivityMonitoring

    func start(onChange: @escaping @Sendable (Bool) -> Void) {
        self.onChange = onChange
        attachDefaultDeviceChangeListener()
        attachToDefaultInput()
        // Emit the current state so the consumer has a baseline and does not
        // treat an already-in-use device as a fresh rising edge.
        onChange(Self.readIsRunning(deviceID))
    }

    func stop() {
        detachRunningListener()
        detachDefaultDeviceChangeListener()
        onChange = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Listener Callbacks (hopped back onto the actor)

    /// The observed device's running-somewhere flag changed.
    private func runningStateChanged() {
        onChange?(Self.readIsRunning(deviceID))
    }

    /// The system default input device changed — move the running listener to it.
    private func defaultInputDeviceChanged() {
        detachRunningListener()
        attachToDefaultInput()
        onChange?(Self.readIsRunning(deviceID))
    }

    // MARK: - Listener Management (actor-isolated)

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
            Task { await self.runningStateChanged() }
        }
        // Pass no dispatch queue: CoreAudio invokes the block on a HAL-owned
        // thread and the block hops back onto the actor.
        let status = AudioObjectAddPropertyListenerBlock(device, &address, nil, block)
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
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
        runningListenerBlock = nil
    }

    private func attachDefaultDeviceChangeListener() {
        var address = Self.defaultInputAddress()
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            Task { await self.defaultInputDeviceChanged() }
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
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
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        defaultDeviceListenerBlock = nil
    }

    // MARK: - CoreAudio Helpers

    /// Fresh property address for the default input device on the system object.
    private nonisolated static func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Fresh property address for a device's "is running somewhere" flag.
    private nonisolated static func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Resolves the current default input device, or `kAudioObjectUnknown`.
    private nonisolated static func defaultInputDevice() -> AudioObjectID {
        var address = defaultInputAddress()
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr ? device : AudioObjectID(kAudioObjectUnknown)
    }

    /// Reads whether `device` is currently in use by any process.
    private nonisolated static func readIsRunning(_ device: AudioObjectID) -> Bool {
        guard device != AudioObjectID(kAudioObjectUnknown) else { return false }
        var address = runningAddress()
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value)
        return status == noErr && value != 0
    }
}
