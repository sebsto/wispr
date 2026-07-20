//
//  MeetingAudioEngine.swift
//  wispr
//
//  Dual audio capture engine for meeting transcription.
//  Captures microphone audio via AVAudioEngine and system audio via ScreenCaptureKit.
//
//  Note: System audio capture requires Screen Recording permission, which macOS
//  prompts for automatically on first use of ScreenCaptureKit. The app must be
//  properly code-signed for macOS to list it in System Settings > Privacy &
//  Security > Screen Recording. If the permission is denied or unavailable,
//  the engine falls back to mic-only capture.
//

import AVFoundation
import CoreAudio
import Foundation
import ScreenCaptureKit
import WisprCore
import os

/// Actor responsible for capturing both microphone and system audio simultaneously.
///
/// Uses `AVAudioEngine` for microphone input and `SCStream` (ScreenCaptureKit)
/// for system audio capture. Both streams are resampled to 16kHz mono Float32.
///
/// If system audio capture fails (e.g. permission denied, sandbox restriction),
/// the engine continues with mic-only capture and logs a warning.
actor MeetingAudioEngine {

    // MARK: - State

    private var micEngine: AVAudioEngine?
    private var systemStream: SCStream?
    private var systemStreamOutput: SystemAudioOutputHandler?

    private var micBuffer: [Float] = []
    private var systemBuffer: [Float] = []

    private var micContinuation: AsyncStream<[Float]>.Continuation?
    private var systemContinuation: AsyncStream<[Float]>.Continuation?
    private var micLevelContinuation: AsyncStream<Float>.Continuation?
    private var systemLevelContinuation: AsyncStream<Float>.Continuation?

    private var micSampleBridgeContinuation: AsyncStream<[Float]>.Continuation?
    private var micConsumerTask: Task<Void, Never>?
    private var systemSampleBridgeContinuation: AsyncStream<[Float]>.Continuation?
    private var systemConsumerTask: Task<Void, Never>?

    private var isCapturing = false

    /// Whether system audio capture is active (may be false if permission denied).
    private var hasSystemAudio = false

    /// The audio chunk streams created at capture start.
    private var _micAudioStream: AsyncStream<[Float]>?
    private var _systemAudioStream: AsyncStream<[Float]>?

    /// The chunk size in samples before yielding to the transcription stream.
    /// ~5 seconds of audio at 16kHz = 80,000 samples.
    private let chunkSize = 80_000

    // MARK: - Public Interface

    /// Starts dual audio capture (microphone + system audio).
    ///
    /// System audio capture may silently fail if Screen Recording permission
    /// is not granted — in that case, only mic capture is active.
    ///
    /// - Returns: A tuple of (micLevelStream, systemLevelStream) for UI visualization.
    /// - Throws: If microphone capture fails to start.
    func startCapture() async throws -> (
        micLevels: AsyncStream<Float>, systemLevels: AsyncStream<Float>
    ) {
        guard !isCapturing else {
            throw WisprError.audioRecordingFailed("Meeting capture already active")
        }

        isCapturing = true
        micBuffer.removeAll()
        systemBuffer.removeAll()

        // Create audio chunk streams upfront so continuations are ready
        // before the taps start producing data.
        let (micStream, micCont) = AsyncStream.makeStream(of: [Float].self)
        _micAudioStream = micStream
        micContinuation = micCont

        let (sysStream, sysCont) = AsyncStream.makeStream(of: [Float].self)
        _systemAudioStream = sysStream
        systemContinuation = sysCont

        let micLevels = startMicCapture()

        // Attempt system audio capture — fall back to mic-only on failure
        let systemLevels: AsyncStream<Float>
        do {
            systemLevels = try await startSystemAudioCapture()
            hasSystemAudio = true
        } catch {
            Log.audioEngine.warning(
                "MeetingAudioEngine — system audio unavailable: \(error.localizedDescription). Continuing with mic only."
            )
            hasSystemAudio = false
            // Return a silent level stream
            let (silentStream, silentCont) = AsyncStream.makeStream(of: Float.self)
            silentCont.finish()
            systemLevels = silentStream
        }

        return (micLevels, systemLevels)
    }

    /// Stops all capture and cleans up resources.
    func stopCapture() async {
        if hasSystemAudio {
            await stopSystemCapture()
        }
        teardownMic()
        teardownSystemAudio()
        isCapturing = false
        hasSystemAudio = false
    }

    /// Returns the mic audio chunk stream created during `startCapture()`.
    var micAudioStream: AsyncStream<[Float]> {
        if let stream = _micAudioStream { return stream }
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        cont.finish()
        return stream
    }

    /// Returns the system audio chunk stream created during `startCapture()`.
    var systemAudioStream: AsyncStream<[Float]> {
        if let stream = _systemAudioStream { return stream }
        let (stream, cont) = AsyncStream.makeStream(of: [Float].self)
        cont.finish()
        return stream
    }

    /// Flushes any remaining buffered audio as final chunks.
    func flushBuffers() {
        if !micBuffer.isEmpty {
            micContinuation?.yield(micBuffer)
            micBuffer.removeAll()
        }
        if !systemBuffer.isEmpty {
            systemContinuation?.yield(systemBuffer)
            systemBuffer.removeAll()
        }
        micContinuation?.finish()
        systemContinuation?.finish()
        micContinuation = nil
        systemContinuation = nil
    }

    // MARK: - Microphone Capture

    private func startMicCapture() -> AsyncStream<Float> {
        let (levelStream, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        self.micLevelContinuation = levelContinuation

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: 1,
                interleaved: false
            )
        else {
            levelContinuation.finish()
            return levelStream
        }

        let (micBridgeStream, micBridgeCont) = AsyncStream.makeStream(of: [Float].self)
        self.micSampleBridgeContinuation = micBridgeCont

        let audioEngine = AVAudioEngine()
        self.micEngine = audioEngine
        let inputNode = audioEngine.inputNode

        nonisolated(unsafe) var converter: AVAudioConverter?
        nonisolated(unsafe) var sampleRateRatio: Double = 0

        let bridgeContinuation = micBridgeCont
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: nil) { buffer, _ in
            guard buffer.frameLength > 0 else { return }

            if converter == nil {
                let bufferFormat = buffer.format
                guard bufferFormat.sampleRate > 0, bufferFormat.channelCount > 0 else { return }
                guard let newConverter = AVAudioConverter(from: bufferFormat, to: targetFormat)
                else { return }
                converter = newConverter
                sampleRateRatio = targetFormat.sampleRate / bufferFormat.sampleRate
            }

            guard let tapConverter = converter else { return }

            let outputFrameCount = AVAudioFrameCount(Double(buffer.frameLength) * sampleRateRatio)
            guard
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: targetFormat,
                    frameCapacity: outputFrameCount
                )
            else { return }

            // Safety: inputBuffer is only read synchronously within the converter's input block callback.
            nonisolated(unsafe) let inputBuffer = buffer
            var conversionError: NSError?
            let status = tapConverter.convert(to: outputBuffer, error: &conversionError) {
                _, outStatus in
                outStatus.pointee = .haveData
                return inputBuffer
            }

            guard status != .error,
                let channelData = outputBuffer.floatChannelData?[0],
                outputBuffer.frameLength > 0
            else { return }

            let samples = Array(
                UnsafeBufferPointer(start: channelData, count: Int(outputBuffer.frameLength)))

            bridgeContinuation.yield(samples)
        }

        do {
            try audioEngine.start()
            Log.audioEngine.debug("MeetingAudioEngine — mic capture started")
        } catch {
            Log.audioEngine.error(
                "MeetingAudioEngine — mic engine start failed: \(error.localizedDescription)")
            teardownMic()
        }

        micConsumerTask = Task {
            for await samples in micBridgeStream {
                self.processMicSamples(samples)
            }
        }

        return levelStream
    }

    private func processMicSamples(_ samples: [Float]) {
        guard isCapturing else { return }

        let sumOfSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        let normalizedLevel = min(max(rms * 5.0, 0.0), 1.0)
        micLevelContinuation?.yield(normalizedLevel)

        micBuffer.append(contentsOf: samples)
        if micBuffer.count >= chunkSize {
            let chunk = Array(micBuffer.prefix(chunkSize))
            micBuffer.removeFirst(min(chunkSize, micBuffer.count))
            Log.audioEngine.debug(
                "MeetingAudioEngine — yielding mic chunk of \(chunk.count) samples")
            micContinuation?.yield(chunk)
        }
    }

    private func teardownMic() {
        micConsumerTask?.cancel()
        micConsumerTask = nil
        micSampleBridgeContinuation?.finish()
        micSampleBridgeContinuation = nil
        guard let engine = micEngine else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        micEngine = nil
        micBuffer.removeAll()
        micContinuation?.finish()
        micContinuation = nil
        micLevelContinuation?.finish()
        micLevelContinuation = nil
        _micAudioStream = nil
    }

    // MARK: - System Audio Capture (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws -> AsyncStream<Float> {
        let (levelStream, levelContinuation) = AsyncStream.makeStream(of: Float.self)
        self.systemLevelContinuation = levelContinuation

        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)

        guard let display = content.displays.first else {
            throw WisprError.audioRecordingFailed("No display found for system audio capture")
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])

        let config = SCStreamConfiguration()
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1

        let (systemBridgeStream, systemBridgeCont) = AsyncStream.makeStream(of: [Float].self)
        self.systemSampleBridgeContinuation = systemBridgeCont

        let handler = SystemAudioOutputHandler { samples in
            systemBridgeCont.yield(samples)
        }
        self.systemStreamOutput = handler

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(
            handler, type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "wispr.meeting.systemAudio"))
        try await stream.startCapture()
        self.systemStream = stream

        systemConsumerTask = Task {
            for await samples in systemBridgeStream {
                self.processSystemSamples(samples)
            }
        }

        Log.audioEngine.debug("MeetingAudioEngine — system audio capture started")
        return levelStream
    }

    private func processSystemSamples(_ samples: [Float]) {
        guard isCapturing else { return }

        let sumOfSquares = samples.reduce(0.0) { $0 + $1 * $1 }
        let rms = sqrt(sumOfSquares / Float(samples.count))
        let normalizedLevel = min(max(rms * 5.0, 0.0), 1.0)
        systemLevelContinuation?.yield(normalizedLevel)

        systemBuffer.append(contentsOf: samples)
        if systemBuffer.count >= chunkSize {
            let chunk = Array(systemBuffer.prefix(chunkSize))
            systemBuffer.removeFirst(min(chunkSize, systemBuffer.count))
            Log.audioEngine.debug(
                "MeetingAudioEngine — yielding system chunk of \(chunk.count) samples")
            systemContinuation?.yield(chunk)
        }
    }

    private func teardownSystemAudio() {
        systemConsumerTask?.cancel()
        systemConsumerTask = nil
        systemSampleBridgeContinuation?.finish()
        systemSampleBridgeContinuation = nil
        systemStream = nil
        systemStreamOutput = nil
        systemBuffer.removeAll()
        systemContinuation?.finish()
        systemContinuation = nil
        systemLevelContinuation?.finish()
        systemLevelContinuation = nil
        _systemAudioStream = nil
    }

    private func stopSystemCapture() async {
        if let stream = systemStream {
            try? await stream.stopCapture()
        }
    }
}

// MARK: - ScreenCaptureKit Audio Output Handler

/// Receives audio sample buffers from SCStream and converts them to Float32 arrays.
final class SystemAudioOutputHandler: NSObject, SCStreamOutput, Sendable {

    private let onSamples: @Sendable ([Float]) -> Void

    nonisolated init(onSamples: @escaping @Sendable ([Float]) -> Void) {
        self.onSamples = onSamples
    }

    nonisolated func stream(
        _ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        guard let blockBuffer = sampleBuffer.dataBuffer else { return }

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &dataPointer)

        guard status == noErr, let data = dataPointer, length > 0 else { return }

        let floatCount = length / MemoryLayout<Float>.size
        guard floatCount > 0 else { return }

        let samples = data.withMemoryRebound(to: Float.self, capacity: floatCount) { ptr in
            Array(UnsafeBufferPointer(start: ptr, count: floatCount))
        }

        onSamples(samples)
    }
}
