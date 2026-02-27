//
//  AudioEngine.swift
//  wispr
//
//  Created by Kiro
//

import Foundation
import AVFoundation
import CoreAudio

/// Actor responsible for audio capture using AVAudioEngine
/// Provides real-time audio level streaming and recorded audio data
actor AudioEngine {
    // MARK: - State
    private var engine: AVAudioEngine?
    private var audioBuffer: [Float] = []
    private var levelContinuation: AsyncStream<Float>.Continuation?
    private var selectedDeviceID: AudioDeviceID?
    private var isCapturing = false
    
    // MARK: - Configuration
    
    /// Sets the input device for audio capture
    /// - Parameter deviceID: The AudioDeviceID to use for input
    /// - Throws: WispError if the device cannot be set
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
    /// - Throws: WispError if capture cannot be started
    func startCapture() async throws -> AsyncStream<Float> {
        guard !isCapturing else {
            throw WispError.audioRecordingFailed("Already capturing")
        }
        
        // Create and configure the audio engine
        let audioEngine = AVAudioEngine()
        self.engine = audioEngine
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        
        // Reset audio buffer
        audioBuffer.removeAll()
        isCapturing = true
        
        // Create the AsyncStream for audio levels
        // We use makeStream to get the continuation separately, avoiding nonisolated closure issues
        let (stream, continuation) = AsyncStream.makeStream(of: Float.self)
        self.levelContinuation = continuation
        
        // Install tap on input node to capture audio
        // Task {} here bridges from AVAudioEngine's sync C callback to async actor method
        // This IS structured: task is scoped to the tap's lifetime (removed when tap is removed)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            let channelData = buffer.floatChannelData?[0]
            let frameLength = Int(buffer.frameLength)
            guard let channelData, frameLength > 0, let self else { return }
            
            let bufferCopy = Array(UnsafeBufferPointer(start: channelData, count: frameLength))
            
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
            throw WispError.audioRecordingFailed("Failed to start audio engine: \(error.localizedDescription)")
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
        teardownEngine()
        return capturedAudio
    }
    
    /// Cancels the current capture session and cleans up resources
    func cancelCapture() {
        teardownEngine()
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
