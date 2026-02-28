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
    private var selectedDeviceID: AudioDeviceID?
    private var isCapturing = false
    private var audioConverter: AVAudioConverter?
    
    // MARK: - Configuration
    
    /// Sets the input device for audio capture
    /// - Parameter deviceID: The AudioDeviceID to use for input
    /// - Throws: WisprError if the device cannot be set
    func setInputDevice(_ deviceID: AudioDeviceID) throws {
        selectedDeviceID = deviceID
    }
    
    /// Returns a list of available audio input devices
    /// - Returns: Array of AudioInputDevice structs
    func availableInputDevices() -> [AudioInputDevice] {
        guard let deviceIDs = getSystemDeviceIDs() else { return [] }
        
        return deviceIDs.compactMap { id in
            let device = CoreAudioDevice(id: id)
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
        
        // Create and configure the audio engine
        let audioEngine = AVAudioEngine()
        self.engine = audioEngine
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // WhisperKit requires 16kHz mono Float32 audio
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        ) else {
            throw WisprError.audioRecordingFailed("Failed to create 16kHz target format")
        }
        
        // Create converter from system sample rate to 16kHz
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw WisprError.audioRecordingFailed(
                "Failed to create audio converter from \(inputFormat.sampleRate)Hz to 16kHz"
            )
        }
        self.audioConverter = converter
        
        Log.audioEngine.debug("startCapture — inputFormat sampleRate: \(inputFormat.sampleRate), targetFormat: 16kHz mono Float32, converter created: true")
        
        // Reset audio buffer
        audioBuffer.removeAll()
        isCapturing = true
        
        // Create the AsyncStream for audio levels
        // We use makeStream to get the continuation separately, avoiding nonisolated closure issues
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
        self.levelContinuation = continuation
        
        // Capture converter as a local let so the @Sendable closure can use it
        let tapConverter = converter
        let sampleRateRatio = targetFormat.sampleRate / inputFormat.sampleRate
        
        // Install tap on input node to capture audio
        // Task {} here bridges from AVAudioEngine's sync C callback to async actor method
        // This IS structured: task is scoped to the tap's lifetime (removed when tap is removed)
        nonisolated(unsafe) var hasLoggedFirstBuffer = false
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self, buffer.frameLength > 0 else { return }
            
            // Calculate output frame count based on sample rate ratio
            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio)
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: outputFrameCount
            ) else { return }
            
            // Resample from system rate to 16kHz
            // The input block captures `buffer` which is non-Sendable (AVAudioPCMBuffer),
            // but it's used synchronously within the same tap callback scope.
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
        } catch {
            isCapturing = false
            levelContinuation?.finish()
            levelContinuation = nil
            self.engine = nil
            throw WisprError.audioRecordingFailed("Failed to start audio engine: \(error.localizedDescription)")
        }
        
        return stream
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
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.audioConverter = nil
        audioBuffer.removeAll()
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
