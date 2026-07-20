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
    /// `onChange` receives the current "in use" state and whether the emission
    /// is a *baseline* seed rather than a real transition. Baseline emissions
    /// happen once when monitoring starts and again whenever the default input
    /// device changes; consumers must seed their state from them but must never
    /// treat them as a rising edge. It may be called from an arbitrary context.
    func start(onChange: @escaping @Sendable (_ isRunning: Bool, _ isBaseline: Bool) -> Void) async

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
    private var onChange: (@Sendable (Bool, Bool) -> Void)?

    // MARK: - InputActivityMonitoring

    func start(onChange: @escaping @Sendable (Bool, Bool) -> Void) {
        self.onChange = onChange
        attachDefaultDeviceChangeListener()
        attachToDefaultInput()
        // Seed the consumer with the current state so an already-in-use device
        // is not mistaken for a fresh rising edge.
        emitCurrentState(isBaseline: true)
    }

    func stop() {
        detachRunningListener()
        detachDefaultDeviceChangeListener()
        onChange = nil
        deviceID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Listener Callbacks (hopped back onto the actor)

    /// The observed device's running-somewhere flag changed — a real transition.
    private func runningStateChanged() {
        emitCurrentState(isBaseline: false)
    }

    /// The system default input device changed — move the running listener to
    /// it and re-seed, so a device switch mid-call is not read as a rising edge.
    private func defaultInputDeviceChanged() {
        detachRunningListener()
        attachToDefaultInput()
        emitCurrentState(isBaseline: true)
    }

    /// Reads the current running state of the observed device and forwards it.
    private func emitCurrentState(isBaseline: Bool) {
        let running =
            deviceID != AudioObjectID(kAudioObjectUnknown)
            ? CoreAudioDevice(id: deviceID).isRunningSomewhere
            : false
        onChange?(running, isBaseline)
    }

    // MARK: - Listener Management (actor-isolated)

    private func attachToDefaultInput() {
        guard let device = CoreAudioDevice.defaultInputDeviceID() else {
            Log.audioEngine.warning("AudioInputActivityMonitor — no default input device")
            return
        }
        deviceID = device

        var address = runningAddress()
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
        var address = runningAddress()
        AudioObjectRemovePropertyListenerBlock(deviceID, &address, nil, block)
        runningListenerBlock = nil
    }

    private func attachDefaultDeviceChangeListener() {
        var address = defaultInputAddress()
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
        var address = defaultInputAddress()
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, nil, block)
        defaultDeviceListenerBlock = nil
    }

    // MARK: - Property Addresses

    /// Property address for the default input device on the system object.
    private func defaultInputAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Property address for a device's "is running somewhere" flag.
    private func runningAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
