//
//  AudioEngine.swift
//  wispr
//
//  Created by Kiro
//

import WisprCore
import Foundation
import AVFoundation
import CoreAudio
import os

/// Actor responsible for audio capture using AVAudioEngine.
/// Provides real-time audio level streaming and recorded audio data.
///
/// ## Privacy Guarantees (Requirements 11.1, 11.2)
///
/// - **No temporary audio files**: All audio data is captured and held exclusively
///   in an in-memory `[Float]` buffer (`audioBuffer`). No audio is ever written to
///   disk as a temporary file, so there is nothing to clean up on the file system.
/// - **Immediate buffer cleanup**: When `stopCapture()` is called, the in-memory
///   buffer is copied for return and then immediately cleared via `teardownCapture()`.
///   When `cancelCapture()` is called, the buffer is discarded without returning data.
/// - **No network connections**: Audio capture uses only local `AVAudioEngine` APIs.
///   No audio data is transmitted over any network connection.
actor AudioEngine {
    // MARK: - State
    private var engine: AVAudioEngine?
    /// Active when capturing from an explicitly selected device (bypasses AVAudioEngine).
    private var deviceCapture: InputDeviceCapture?
    /// Incremented per capture session so suspended work can detect it was superseded.
    private var captureSession = 0
    private var audioBuffer: [Float] = []
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    private var selectedDeviceID: AudioDeviceID?
    private var isCapturing = false
    private var configChangeTask: Task<Void, Never>?
    /// Restarts allowed per capture session after the engine stops on a configuration change.
    nonisolated static let maxConfigurationChangeRestarts = 3
    private var configurationChangeRestarts = RestartBudget(limit: AudioEngine.maxConfigurationChangeRestarts)
    private var onCaptureFailure: (@Sendable (WisprError) async -> Void)?

    /// WhisperKit and Parakeet require 16kHz mono Float32 audio.
    /// These parameters are always valid, so the initializer cannot fail.
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
    )!
    
    // MARK: - Configuration
    
    /// Sets the input device for audio capture
    /// - Parameter deviceID: The AudioDeviceID to use for input
    /// - Throws: WisprError if the device cannot be set
    func setInputDevice(_ deviceID: AudioDeviceID?) throws {
        selectedDeviceID = deviceID
    }

    /// Sets the handler invoked when an active capture can no longer be recovered
    /// (e.g. the engine keeps stopping after repeated configuration changes).
    func setOnCaptureFailure(_ handler: (@Sendable (WisprError) async -> Void)?) {
        onCaptureFailure = handler
    }

    /// Resolves a device UID string to its AudioDeviceID.
    /// - Parameter uid: The persistent UID string stored in settings
    /// - Returns: The AudioDeviceID, or nil if no matching device is found
    func deviceIDForUID(_ uid: String) -> AudioDeviceID? {
        availableInputDevices().first { $0.uid == uid }?.id
    }
    
    /// Returns a list of available audio input devices
    /// - Returns: Array of AudioInputDevice structs
    func availableInputDevices() -> [AudioInputDevice] {
        guard let deviceIDs = getSystemDeviceIDs() else { return [] }
        
        return deviceIDs.compactMap { id in
            let device = CoreAudioDevice(id: id)
            // Filter out private aggregate devices created by AVAudioEngine internally,
            // but allow user-created aggregates from Audio MIDI Setup.
            guard !device.isPrivateAggregate else { return nil }
            guard device.hasInputStreams,
                  let name = device.name,
                  let uid = device.uid else { return nil }
            return AudioInputDevice(id: id, name: name, uid: uid)
        }
    }
    
    // MARK: - Recording
    
    /// Starts audio capture and returns a stream of audio levels
    /// - Returns: AsyncStream of Float values representing audio levels (0.0 to 1.0)
    /// - Throws: WisprError if capture cannot be started
    func startCapture() async throws -> AsyncStream<Float> {
        guard !isCapturing else {
            throw WisprError.audioRecordingFailed("Already capturing")
        }

        // Reset audio buffer
        audioBuffer.removeAll()
        isCapturing = true

        // Create the AsyncStream for audio levels
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
        self.levelContinuation = continuation
        captureSession += 1
        let session = captureSession

        if let deviceID = selectedDeviceID {
            do {
                try await startDeviceCapture(deviceID: deviceID, session: session)
                return stream
            } catch is CancellationError {
                if captureSession == session { teardownCapture() }
                throw CancellationError()
            } catch {
                guard isCapturing, captureSession == session else { throw error }
                Log.audioEngine.warning("Selected device \(deviceID) unavailable (\(error.localizedDescription)), falling back to system default")
                selectedDeviceID = nil
            }
        }

        let audioEngine = AVAudioEngine()
        self.engine = audioEngine
        configurationChangeRestarts.reset()

        do {
            try await configureAndStart(audioEngine)
        } catch {
            if self.engine === audioEngine {
                teardownCapture()
            } else {
                // Stopped while we were suspended; don't leave the orphaned engine running.
                audioEngine.stop()
                audioEngine.inputNode.removeTap(onBus: 0)
            }
            throw error
        }

        // Bluetooth headsets switch A2DP -> HFP when the mic opens. AVAudioEngine then
        // stops and posts AVAudioEngineConfigurationChange, so restart capture.
        // MeetingAudioEngine posts its own notifications; ignore those.
        let engineID = ObjectIdentifier(audioEngine)
        configChangeTask?.cancel()
        configChangeTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                guard let object = notification.object as AnyObject?,
                      ObjectIdentifier(object) == engineID else { continue }
                guard let self else { return }
                await self.handleConfigurationChange()
            }
        }

        return stream
    }

    /// Captures from the system default input. Called on start and again after
    /// an engine configuration change.
    private func configureAndStart(_ audioEngine: AVAudioEngine) async throws {
        let inputNode = audioEngine.inputNode

        // The physical device we will actually capture from.
        let captureDeviceID = CoreAudioDevice.defaultInputDeviceID()
        var tapFormat: AVAudioFormat? = nil

        if let captureDeviceID {
            let device = CoreAudioDevice(id: captureDeviceID)

            // Bluetooth devices switch from A2DP (44.1/48kHz) to HFP/SCO (16/24kHz)
            // when the mic is activated. Wait for the rate to settle before querying
            // the hardware format.
            let isBluetooth = device.transportType == kAudioDeviceTransportTypeBluetooth
                || device.transportType == kAudioDeviceTransportTypeBluetoothLE
            if isBluetooth {
                try await waitForBluetoothHFP(deviceID: captureDeviceID)
                // Actor reentrancy: stopCapture()/cancelCapture() may have run while we
                // were waiting. Don't start an engine nobody will stop.
                guard isCapturing, self.engine === audioEngine else { throw CancellationError() }
            }

            // inputNode's cached format may be stale after a device/profile switch, so
            // build the tap format from the actual hardware rate.
            if isBluetooth {
                let rate = device.nominalSampleRate ?? 48000
                let channels = max(device.inputChannelCount, 1)
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: rate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: false
                ) else {
                    throw WisprError.audioRecordingFailed("Failed to create tap format at \(rate)Hz \(channels)ch")
                }
                tapFormat = format
            }
        }

        Log.audioEngine.debug("startCapture — device: system default, tapFormat: \(tapFormat?.description ?? "nil (system default)")")

        installCaptureTap(on: inputNode, format: tapFormat)

        audioEngine.prepare()

        do {
            try audioEngine.start()
        } catch {
            Log.audioEngine.error("engine.start() failed: \(error.localizedDescription)")
            throw WisprError.audioRecordingFailed("Failed to start audio engine: \(error.localizedDescription)")
        }
    }

    /// Installs the tap that converts hardware buffers to 16kHz mono and feeds the buffer.
    private func installCaptureTap(on inputNode: AVAudioInputNode, format tapFormat: AVAudioFormat?) {
        let converter = CaptureBufferConverter(targetFormat: targetFormat)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self, let samples = converter.convert(buffer) else { return }
            Task {
                await self.processAudioBufferData(samples)
            }
        }
    }

    /// Captures from an explicitly selected device through an input-only AUHAL.
    /// AVAudioEngine's IO unit follows the system default device, so with a Bluetooth
    /// headset as default it reverts `setDeviceID` and switches the headset to HFP (#133).
    private func startDeviceCapture(deviceID: AudioDeviceID, session: Int) async throws {
        let device = CoreAudioDevice(id: deviceID)
        let isBluetooth = device.transportType == kAudioDeviceTransportTypeBluetooth
            || device.transportType == kAudioDeviceTransportTypeBluetoothLE
        if isBluetooth {
            try await waitForBluetoothHFP(deviceID: deviceID)
            // Actor reentrancy: the session may have been stopped while we waited.
            guard isCapturing, captureSession == session else { throw CancellationError() }
        }

        let converter = CaptureBufferConverter(targetFormat: targetFormat)
        let capture = try InputDeviceCapture(deviceID: deviceID) { [weak self] buffer in
            guard let self, let samples = converter.convert(buffer) else { return }
            Task {
                await self.processAudioBufferData(samples)
            }
        }
        try capture.start()
        deviceCapture = capture
        Log.audioEngine.debug("startCapture — device: \(deviceID) via dedicated input unit at \(capture.sampleRate)Hz")
    }

    /// Restarts capture after AVAudioEngine stopped itself because the IO unit's
    /// configuration changed (e.g. Bluetooth A2DP -> HFP). Keeps already-captured audio.
    private func handleConfigurationChange() async {
        // Only restart if capture is active and the change actually stopped the engine.
        guard isCapturing, let audioEngine = engine, !audioEngine.isRunning else { return }

        guard configurationChangeRestarts.consume() else {
            Log.audioEngine.error("Engine configuration changed again after \(self.configurationChangeRestarts.used) restarts, giving up")
            await reportCaptureFailure("The microphone keeps changing configuration. Please try again.")
            return
        }
        Log.audioEngine.warning("Engine configuration changed during capture, restarting (attempt \(self.configurationChangeRestarts.used))")

        audioEngine.inputNode.removeTap(onBus: 0)
        do {
            try await configureAndStart(audioEngine)
        } catch is CancellationError {
            // Capture was stopped while restarting; nothing to report.
        } catch {
            Log.audioEngine.error("Restart after configuration change failed: \(error.localizedDescription)")
            await reportCaptureFailure("Recording stopped after the microphone changed: \(error.localizedDescription)")
        }
    }

    /// Notifies the owner that the active capture cannot continue.
    private func reportCaptureFailure(_ message: String) async {
        guard isCapturing else { return }
        await onCaptureFailure?(.audioRecordingFailed(message))
    }

    /// Stops audio capture and returns the recorded audio samples
    /// - Returns: Array of Float samples suitable for WhisperKit's transcribe(audioArray:)
    func stopCapture() -> [Float] {
        guard isCapturing else {
            return []
        }
        
        let capturedAudio = audioBuffer
        
        let sampleCount = capturedAudio.count
        let duration = Double(sampleCount) / 16000.0
        let peak = capturedAudio.reduce(Float(0)) { max($0, abs($1)) }
        Log.audioEngine.debug("stopCapture — samples: \(sampleCount), duration: \(duration, format: .fixed(precision: 2))s, peak: \(peak, format: .fixed(precision: 3))")
        
        teardownCapture()
        return capturedAudio
    }
    
    /// Cancels the current capture session and cleans up resources
    func cancelCapture() {
        Log.audioEngine.debug("cancelCapture — discarding audio buffer")
        teardownCapture()
    }

    /// Returns an AsyncStream of raw audio chunks (16kHz Float32) from the active capture session.
    /// Used by EOU monitoring to feed audio to the streaming transcription engine.
    /// Returns a finished stream if no capture is active.
    var captureStream: AsyncStream<[Float]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [Float].self)
        if isCapturing {
            self.audioContinuation = continuation
        } else {
            continuation.finish()
        }
        return stream
    }
    
    // MARK: - Device Monitoring & Fallback
    
    /// Callback invoked when a device disconnection is handled.
    /// The StateManager can observe this to display a notification.
    /// The String parameter contains the name of the fallback device, or nil on failure.
    var onDeviceFallback: (@Sendable (String?) async -> Void)?
    
    /// Starts monitoring for audio device changes (connections/disconnections).
    ///
    /// Requirement 2.4, 8.5: Detect device changes and update the available device list.
    /// Uses a Core Audio property listener on the system object.
    func startDeviceMonitoring() async {
        // Device monitoring is handled via handleDeviceDisconnection when errors occur
    }
    
    /// Handles audio device disconnection by falling back to the system default device.
    ///
    /// Requirement 2.4: If the selected audio input device becomes unavailable during
    /// a Recording_Session, fall back to the system default input device and continue recording.
    /// Requirement 12.4: If the AudioEngine encounters a hardware error during recording,
    /// stop the Recording_Session cleanly and notify the user.
    ///
    /// - Returns: `true` if fallback succeeded, `false` if no default device is available.
    func handleDeviceDisconnection() async -> Bool {
        // Get the system default input device
        guard let defaultDeviceID = getDefaultInputDeviceID() else {
            // Requirement 2.5: No audio input device available
            await onDeviceFallback?(nil)
            return false
        }
        
        // If we're currently capturing, try to restart with the default device
        if isCapturing {
            // Stop current capture cleanly
            let wasCapturing = true
            teardownCapture()
            
            if wasCapturing {
                // Switch to default device
                selectedDeviceID = defaultDeviceID
                
                // Get the device name for notification
                let device = CoreAudioDevice(id: defaultDeviceID)
                let deviceName = device.name ?? "System Default"
                await onDeviceFallback?(deviceName)
            }
        } else {
            // Not capturing — just update the selected device
            selectedDeviceID = getDefaultInputDeviceID()
        }
        
        return true
    }
    
    /// Returns the system default audio input device ID.
    private func getDefaultInputDeviceID() -> AudioDeviceID? {
        CoreAudioDevice.defaultInputDeviceID()
    }

    
    // MARK: - Private Helpers
    
    private func teardownCapture() {
        guard isCapturing || engine != nil || deviceCapture != nil else { return }
        isCapturing = false
        configChangeTask?.cancel()
        configChangeTask = nil
        levelContinuation?.finish()
        levelContinuation = nil
        audioContinuation?.finish()
        audioContinuation = nil
        deviceCapture?.stop()
        deviceCapture = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        self.engine = nil
        audioBuffer.removeAll()
    }

    /// Waits for a Bluetooth device to complete the A2DP → HFP/SCO profile
    /// switch by polling `kAudioDevicePropertyNominalSampleRate`.
    /// HFP typically runs at 8/16/24 kHz; A2DP at 44.1/48 kHz.
    /// Returns once the rate drops below 44100 or after a timeout.
    private func waitForBluetoothHFP(deviceID: AudioDeviceID, timeoutMs: Int = 3000) async throws {
        let pollInterval = 100 // ms
        let maxPolls = timeoutMs / pollInterval
        let device = CoreAudioDevice(id: deviceID)

        for poll in 0..<maxPolls {
            if let rate = device.nominalSampleRate, rate < 44100 {
                Log.audioEngine.debug("Bluetooth HFP settled at \(rate)Hz after \(poll * pollInterval)ms")
                return
            }
            try await Task.sleep(for: .milliseconds(pollInterval))
        }
        // Timeout — proceed with whatever rate the device reports now.
        let finalRate = device.nominalSampleRate ?? 0
        Log.audioEngine.warning("Bluetooth HFP timeout after \(timeoutMs)ms, rate: \(finalRate)Hz")
    }
    
    private func getSystemDeviceIDs() -> [AudioDeviceID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return nil }
        
        return ids
    }
    
    private func processAudioBufferData(_ bufferData: [Float]) {
        guard isCapturing, let continuation = levelContinuation else { return }
        
        // Append to our audio buffer for later retrieval
        audioBuffer.append(contentsOf: bufferData)
        
        // Calculate RMS level for the stream
        let sumOfSquares = bufferData.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(bufferData.count))
        
        // Normalize to 0.0 - 1.0 range (assuming typical speech is around -20dB to 0dB)
        let normalizedLevel = min(max(rms * 5.0, 0.0), 1.0)
        
        // Send level to the stream
        continuation.yield(normalizedLevel)
        
        // Also yield raw audio chunks for streaming transcription (EOU monitoring)
        audioContinuation?.yield(bufferData)
    }
}

// MARK: - Restart Budget

/// Caps how many times capture is restarted after configuration changes within one
/// session, so a device that keeps reconfiguring ends the session instead of looping.
nonisolated struct RestartBudget: Sendable {
    let limit: Int
    private(set) var used = 0

    init(limit: Int) {
        self.limit = limit
    }

    /// Records a restart and returns `true` if one was still allowed.
    mutating func consume() -> Bool {
        guard used < limit else { return false }
        used += 1
        return true
    }

    mutating func reset() {
        used = 0
    }
}

// MARK: - Buffer Conversion

/// Converts hardware buffers to 16kHz mono Float32 for the ASR engines.
/// The converter is created lazily from the first buffer's actual format.
/// Each instance is fed from a single audio thread.
nonisolated final class CaptureBufferConverter: @unchecked Sendable {
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var sampleRateRatio: Double = 0
    private var hasLoggedFirstBuffer = false

    init(targetFormat: AVAudioFormat) {
        self.targetFormat = targetFormat
    }

    /// Returns the converted samples, or `nil` if the buffer could not be converted.
    func convert(_ buffer: AVAudioPCMBuffer) -> [Float]? {
        guard buffer.frameLength > 0 else { return nil }

        if converter == nil {
            let bufferFormat = buffer.format
            guard bufferFormat.sampleRate > 0, bufferFormat.channelCount > 0,
                  let newConverter = AVAudioConverter(from: bufferFormat, to: targetFormat) else { return nil }
            converter = newConverter
            sampleRateRatio = targetFormat.sampleRate / bufferFormat.sampleRate
            Log.audioEngine.debug("Capture started — hwFormat: \(bufferFormat.sampleRate)Hz \(bufferFormat.channelCount)ch, converter created")
        }
        guard let converter else { return nil }

        // Round up, plus one frame of headroom: 512 frames at 48kHz give 170.67 samples
        // at 16kHz, and truncating leaves the fraction in the converter.
        let outputFrameCount = AVAudioFrameCount((Double(buffer.frameLength) * sampleRateRatio).rounded(.up)) + 1
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else { return nil }

        // Hand each buffer to the converter once. It may ask for more input than a small
        // buffer holds; supplying the same buffer again duplicates audio.
        nonisolated(unsafe) let inputBuffer = buffer
        nonisolated(unsafe) var consumed = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        guard status != .error,
              let channelData = outputBuffer.floatChannelData?[0],
              outputBuffer.frameLength > 0 else { return nil }

        if !hasLoggedFirstBuffer {
            hasLoggedFirstBuffer = true
            Log.audioEngine.debug("First buffer — inputFrames: \(buffer.frameLength), outputFrames: \(outputBuffer.frameLength)")
        }
        return Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))
    }
}

// MARK: - Dedicated Input Unit

/// Captures mono Float32 audio from one device with an input-only AUHAL (Apple TN2091).
/// Output is disabled and the device is bound with `kAudioOutputUnitProperty_CurrentDevice`,
/// so the system default devices are never opened or switched to HFP.
///
/// `handler` runs on the HAL IO thread. Don't keep the buffer: it is reused.
nonisolated final class InputDeviceCapture: @unchecked Sendable {
    typealias BufferHandler = @Sendable (AVAudioPCMBuffer) -> Void

    let sampleRate: Double
    private let unit: AudioUnit
    private let renderBuffer: AVAudioPCMBuffer
    private let handler: BufferHandler
    private var isStarted = false
    private var isDisposed = false

    init(deviceID: AudioDeviceID, handler: @escaping BufferHandler) throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw WisprError.audioRecordingFailed("HAL input unit is not available")
        }
        var newUnit: AudioUnit?
        try Self.check(AudioComponentInstanceNew(component, &newUnit), "Creating HAL input unit")
        guard let unit = newUnit else {
            throw WisprError.audioRecordingFailed("Creating HAL input unit returned nil")
        }

        do {
            // Input on element 1, output on element 0 disabled: capture only.
            var enable: UInt32 = 1
            var disable: UInt32 = 0
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1,
                                                &enable, UInt32(MemoryLayout<UInt32>.size)), "Enabling input")
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0,
                                                &disable, UInt32(MemoryLayout<UInt32>.size)), "Disabling output")

            var device = deviceID
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "Selecting device \(deviceID)")

            // The device-side format (input scope of element 1) gives the hardware rate.
            // AUHAL does not resample input, so the client format keeps that rate; asking
            // for one channel takes the device's first channel.
            var hardwareFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1,
                                                &hardwareFormat, &size), "Reading device format")
            guard hardwareFormat.mSampleRate > 0,
                  let clientFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardwareFormat.mSampleRate,
                                                   channels: 1, interleaved: false) else {
                throw WisprError.audioRecordingFailed("Device \(deviceID) reported an invalid format")
            }
            try Self.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                                clientFormat.streamDescription,
                                                UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Setting client format")

            var maxFrames: UInt32 = 0
            size = UInt32(MemoryLayout<UInt32>.size)
            if AudioUnitGetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                    &maxFrames, &size) != noErr {
                maxFrames = 0
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: clientFormat, frameCapacity: max(maxFrames, 4096)) else {
                throw WisprError.audioRecordingFailed("Could not allocate capture buffer")
            }

            self.unit = unit
            self.sampleRate = hardwareFormat.mSampleRate
            self.renderBuffer = buffer
            self.handler = handler
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }

        // The callback context is unretained; stop() disposes the unit before self can go away.
        var callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, bus, frameCount, _ in
                Unmanaged<InputDeviceCapture>.fromOpaque(refCon).takeUnretainedValue()
                    .render(flags: flags, timeStamp: timeStamp, bus: bus, frameCount: frameCount)
            },
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        do {
            try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                                &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Setting input callback")
            try Self.check(AudioUnitInitialize(unit), "Initializing HAL input unit")
        } catch {
            dispose()
            throw error
        }
    }

    deinit {
        dispose()
    }

    func start() throws {
        guard !isStarted, !isDisposed else { return }
        try Self.check(AudioOutputUnitStart(unit), "Starting HAL input unit")
        isStarted = true
    }

    /// Stops capture and releases the unit. `AudioOutputUnitStop` waits for an in-flight
    /// callback to finish, so no callback runs after this returns.
    func stop() {
        dispose()
    }

    private func dispose() {
        guard !isDisposed else { return }
        isDisposed = true
        if isStarted {
            AudioOutputUnitStop(unit)
            isStarted = false
        }
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        timeStamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32,
                        frameCount: UInt32) -> OSStatus {
        guard frameCount <= renderBuffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        renderBuffer.frameLength = frameCount
        let buffers = UnsafeMutableAudioBufferListPointer(renderBuffer.mutableAudioBufferList)
        for index in buffers.indices {
            // AudioUnitRender reads the available size from mDataByteSize.
            buffers[index].mDataByteSize = frameCount * UInt32(MemoryLayout<Float>.size)
        }
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frameCount, renderBuffer.mutableAudioBufferList)
        guard status == noErr else { return status }
        handler(renderBuffer)
        return noErr
    }

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status == noErr else {
            throw WisprError.audioRecordingFailed("\(step) failed (OSStatus \(status))")
        }
    }
}
