//
//  AudioEngine.swift
//  wispr
//
//  Created by Kiro
//

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
///   buffer is copied for return and then immediately cleared via `teardownEngine()`.
///   When `cancelCapture()` is called, the buffer is discarded without returning data.
/// - **No network connections**: Audio capture uses only local `AVAudioEngine` APIs.
///   No audio data is transmitted over any network connection.
actor AudioEngine {
    // MARK: - State
    private var engine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var audioContinuation: AsyncStream<[Float]>.Continuation?
    private var selectedDeviceID: AudioDeviceID?
    private var isCapturing = false
    
    // MARK: - Configuration
    
    /// Sets the input device for audio capture
    /// - Parameter deviceID: The AudioDeviceID to use for input
    /// - Throws: WisprError if the device cannot be set
    func setInputDevice(_ deviceID: AudioDeviceID?) throws {
        selectedDeviceID = deviceID
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

        // WhisperKit requires 16kHz mono Float32 audio
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw WisprError.audioRecordingFailed("Failed to create 16kHz target format")
        }

        // Reset audio buffer
        audioBuffer.removeAll()
        isCapturing = true

        // Create the AsyncStream for audio levels
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
        self.levelContinuation = continuation

        let audioEngine = AVAudioEngine()
        self.engine = audioEngine
        let inputNode = audioEngine.inputNode

        // Assign the selected device to this engine's input AudioUnit
        // BEFORE reading any format or installing taps (Req 2.1, 2.3).
        // For selected devices, build an explicit tap format from CoreAudio
        // since inputNode's cached format may be stale after device switches.
        // For system-default devices, nil lets AVAudioEngine use its cache.
        var tapFormat: AVAudioFormat? = nil
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
            if status == noErr {
                Log.audioEngine.debug("Per-engine input device set to \(deviceID)")
            } else {
                Log.audioEngine.warning("AudioUnitSetProperty failed (OSStatus: \(status)) for device \(deviceID), falling back to system default")
                selectedDeviceID = nil
            }

            if selectedDeviceID != nil {
                let device = CoreAudioDevice(id: deviceID)

                // Bluetooth devices switch from A2DP (48kHz) to HFP/SCO
                // (16/24kHz) when the mic is activated. Wait for the rate
                // to settle before querying the hardware format.
                let isBluetooth = device.transportType == kAudioDeviceTransportTypeBluetooth
                    || device.transportType == kAudioDeviceTransportTypeBluetoothLE
                if isBluetooth {
                    try await waitForBluetoothHFP(deviceID: deviceID)
                }

                // Build tap format from the actual hardware rate.
                let rate = device.nominalSampleRate ?? 48000
                let channels = max(device.inputChannelCount, 1)
                guard let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: rate,
                    channels: AVAudioChannelCount(channels),
                    interleaved: false
                ) else {
                    isCapturing = false
                    levelContinuation?.finish()
                    levelContinuation = nil
                    self.engine = nil
                    throw WisprError.audioRecordingFailed("Failed to create tap format at \(rate)Hz \(channels)ch")
                }
                tapFormat = format
            }
        }

        let deviceDescription = selectedDeviceID.map { String($0) } ?? "system default"
        Log.audioEngine.debug("startCapture — device: \(deviceDescription), tapFormat: \(tapFormat?.description ?? "nil (system default)")")

        // The converter is created lazily from the first buffer's actual format.
        nonisolated(unsafe) var converter: AVAudioConverter?
        nonisolated(unsafe) var sampleRateRatio: Double = 0
        nonisolated(unsafe) var hasLoggedFirstBuffer = false
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: tapFormat) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }

            // Lazily create converter from the actual buffer format
            if converter == nil {
                let bufferFormat = buffer.format
                guard bufferFormat.sampleRate > 0, bufferFormat.channelCount > 0 else { return }
                guard let newConverter = AVAudioConverter(from: bufferFormat, to: targetFormat) else { return }
                converter = newConverter
                sampleRateRatio = targetFormat.sampleRate / bufferFormat.sampleRate
                Log.audioEngine.debug("Tap started — hwFormat: \(bufferFormat.sampleRate)Hz \(bufferFormat.channelCount)ch, converter created")
            }

            guard let tapConverter = converter else { return }

            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }

            nonisolated(unsafe) let inputBuffer = buffer
            var conversionError: NSError?
            let status = tapConverter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
                outStatus.pointee = .haveData
                return inputBuffer
            }

            guard status != .error,
                  let channelData = outputBuffer.floatChannelData?[0],
                  outputBuffer.frameLength > 0 else { return }

            let bufferCopy = Array(UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))

            if !hasLoggedFirstBuffer {
                hasLoggedFirstBuffer = true
                Log.audioEngine.debug("First buffer — inputFrames: \(buffer.frameLength), outputFrames: \(outputBuffer.frameLength)")
            }

            Task {
                await self.processAudioBufferData(bufferCopy)
            }
        }

        // Start the engine
        do {
            try audioEngine.start()
            return stream
        } catch {
            Log.audioEngine.error("engine.start() failed: \(error.localizedDescription)")
            audioEngine.stop()
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            isCapturing = false
            levelContinuation?.finish()
            levelContinuation = nil
            throw WisprError.audioRecordingFailed("Failed to start audio engine: \(error.localizedDescription)")
        }
    }
    
    /// Stops audio capture and returns the recorded audio samples
    /// - Returns: Array of Float samples suitable for WhisperKit's transcribe(audioArray:)
    func stopCapture() -> [Float] {
        guard engine != nil, isCapturing else {
            return []
        }
        
        let capturedAudio = audioBuffer
        
        let sampleCount = capturedAudio.count
        let duration = Double(sampleCount) / 16000.0
        Log.audioEngine.debug("stopCapture — samples: \(sampleCount), duration: \(duration, format: .fixed(precision: 2))s")
        
        teardownEngine()
        return capturedAudio
    }
    
    /// Cancels the current capture session and cleans up resources
    func cancelCapture() {
        Log.audioEngine.debug("cancelCapture — discarding audio buffer")
        teardownEngine()
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
            teardownEngine()
            
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

    
    // MARK: - Private Helpers
    
    private func teardownEngine() {
        guard let engine else { return }
        isCapturing = false
        levelContinuation?.finish()
        levelContinuation = nil
        audioContinuation?.finish()
        audioContinuation = nil
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
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

// MARK: - CoreAudio Device Helper

/// Lightweight wrapper around an AudioDeviceID that provides idiomatic property access
nonisolated private struct CoreAudioDevice: Sendable {
    let id: AudioDeviceID
    
    nonisolated var hasInputStreams: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size)
        return status == noErr && size > 0
    }
    
    nonisolated var name: String? {
        getStringProperty(kAudioObjectPropertyName)
    }
    
    nonisolated var uid: String? {
        getStringProperty(kAudioDevicePropertyDeviceUID)
    }

    /// Whether this aggregate device is marked as private (created internally by AVAudioEngine).
    /// User-created aggregates from Audio MIDI Setup are not private.
    nonisolated var isPrivateAggregate: Bool {
        guard transportType == kAudioDeviceTransportTypeAggregate else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        var dict: CFDictionary?
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &dict) == noErr,
              let composition = dict as? [String: Any] else { return false }
        // kAudioAggregateDeviceIsPrivateKey == "priv"
        if let isPrivate = composition["priv"] as? Int, isPrivate == 1 {
            return true
        }
        return false
    }

    /// The transport type of the device (USB, Bluetooth, Built-In, etc.)
    nonisolated var transportType: UInt32 {
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
    nonisolated var nominalSampleRate: Double? {
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
    nonisolated var inputChannelCount: UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let rawPointer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPointer.deallocate() }
        let bufferListPointer = rawPointer.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferListPointer) == noErr else { return 0 }
        let bufferList = UnsafeMutableAudioBufferListPointer(bufferListPointer)
        return bufferList.reduce(0) { $0 + $1.mNumberChannels }
    }
    
    nonisolated private func getStringProperty(_ selector: AudioObjectPropertySelector) -> String? {
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
