//
//  AudioCaptureConversionTests.swift
//  wispr
//
//  Unit tests for the capture conversion path and the configuration-change
//  restart cap (issue #133). Pure logic only: no audio hardware needed.
//

import Testing
import Foundation
import AVFoundation
@testable import WisprApp

// MARK: - Helpers

private let asrFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!

/// Builds a mono buffer of a rising ramp, starting at overall sample `startIndex`.
private func rampBuffer(sampleRate: Double, frames: Int, startIndex: Int, step: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    let data = buffer.floatChannelData![0]
    for i in 0..<frames {
        data[i] = Float(startIndex + i) * step
    }
    return buffer
}

/// Feeds one second of a rising ramp through the converter in `chunk`-frame buffers,
/// the way the AUHAL (512) or the engine tap delivers them.
private func convertOneSecondRamp(sampleRate: Double, chunk: Int) -> [Float] {
    let converter = CaptureBufferConverter(targetFormat: asrFormat)
    let totalFrames = Int(sampleRate)
    let step = Float(0.9) / Float(totalFrames)
    var output: [Float] = []
    var index = 0
    while index < totalFrames {
        let frames = min(chunk, totalFrames - index)
        if let samples = converter.convert(rampBuffer(sampleRate: sampleRate, frames: frames, startIndex: index, step: step)) {
            output.append(contentsOf: samples)
        }
        index += frames
    }
    return output
}

/// Largest drop between consecutive samples. A resampled rising ramp never drops by more
/// than filter ripple; feeding a buffer twice makes the signal jump back by a whole chunk.
private func largestBackwardJump(_ samples: [Float]) -> Float {
    zip(samples, samples.dropFirst()).map { $0 - $1 }.max() ?? 0
}

// MARK: - CaptureBufferConverter

@Suite("CaptureBufferConverter")
struct CaptureBufferConverterTests {

    @Test("48 kHz audio in 512-frame buffers converts to 16 kHz without duplicating samples")
    func convertsSmallBuffersWithoutDuplication() {
        let output = convertOneSecondRamp(sampleRate: 48000, chunk: 512)

        // One second at 16kHz, minus the converter's start-up latency.
        #expect(output.count >= 15_980)
        #expect(output.count <= 16_000)
        // A duplicated 512-frame chunk would jump back by about 0.0096.
        #expect(largestBackwardJump(output) < 0.001)
    }

    @Test("44.1 kHz audio in engine-tap-sized buffers converts to 16 kHz")
    func convertsTapSizedBuffers() {
        let output = convertOneSecondRamp(sampleRate: 44100, chunk: 4410)

        #expect(output.count > 15_500)
        #expect(output.count <= 16_000)
        #expect(largestBackwardJump(output) < 0.001)
    }

    @Test("An empty buffer produces no samples")
    func emptyBufferReturnsNil() {
        let converter = CaptureBufferConverter(targetFormat: asrFormat)
        let empty = rampBuffer(sampleRate: 48000, frames: 0, startIndex: 0, step: 0)

        #expect(converter.convert(empty) == nil)
    }
}

// MARK: - Configuration-change restart cap

@Suite("Configuration change restart cap")
struct RestartBudgetTests {

    @Test("Capture is restarted at most 3 times per session")
    func allowsThreeRestarts() {
        #expect(AudioEngine.maxConfigurationChangeRestarts == 3)
        var budget = RestartBudget(limit: AudioEngine.maxConfigurationChangeRestarts)

        let allowed = (1...4).map { _ in budget.consume() }

        #expect(allowed == [true, true, true, false], "A fourth configuration change should end the session")
        #expect(budget.used == 3)
    }

    @Test("A new session gets a fresh restart budget")
    func resetRestoresBudget() {
        var budget = RestartBudget(limit: AudioEngine.maxConfigurationChangeRestarts)
        while budget.consume() {}

        budget.reset()

        let allowedAfterReset = budget.consume()

        #expect(allowedAfterReset)
        #expect(budget.used == 1)
    }
}
