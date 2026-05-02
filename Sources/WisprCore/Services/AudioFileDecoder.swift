//
//  AudioFileDecoder.swift
//  wispr
//
//  Decodes audio/video files into 16 kHz mono PCM Float32 samples
//  suitable for transcription engines. Uses AVAssetReader for decoding —
//  supports all formats that AVFoundation/CoreAudio can handle
//  (MP3, WAV, M4A, FLAC, AAC, MP4, MOV, etc.) with no additional dependencies.
//

import AVFoundation

public actor AudioFileDecoder {

    /// Decoded audio metadata returned alongside samples.
    nonisolated public struct AudioMetadata: Sendable {
        public let duration: TimeInterval
        public let sampleRate: Double
        public let channelCount: Int
        public let estimatedSampleCount: Int

        public init(duration: TimeInterval, sampleRate: Double, channelCount: Int, estimatedSampleCount: Int) {
            self.duration = duration
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.estimatedSampleCount = estimatedSampleCount
        }
    }

    private static let targetSampleRate: Double = 16_000
    private static let targetChannelCount: AVAudioChannelCount = 1

    public init() {}

    /// Audio output settings for 16 kHz mono Float32 PCM.
    private static var outputSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
    }

    // MARK: - Metadata

    public func metadata(for fileURL: URL) async throws -> AudioMetadata {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioDecoderError.fileNotFound(fileURL.path)
        }

        let asset = AVURLAsset(url: fileURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw AudioDecoderError.noAudioTrack(fileURL.path)
        }

        let duration = try await asset.load(.duration)
        let formatDescriptions = try await track.load(.formatDescriptions)

        var sampleRate: Double = 0
        var channelCount: Int = 0
        if let formatDesc = formatDescriptions.first {
            let basicDesc = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
            sampleRate = basicDesc?.pointee.mSampleRate ?? 0
            channelCount = Int(basicDesc?.pointee.mChannelsPerFrame ?? 0)
        }

        let durationSeconds = CMTimeGetSeconds(duration)
        let estimatedSamples = Int(durationSeconds * Self.targetSampleRate)

        return AudioMetadata(
            duration: durationSeconds,
            sampleRate: sampleRate,
            channelCount: channelCount,
            estimatedSampleCount: estimatedSamples
        )
    }

    // MARK: - Full Decode

    public func decode(fileURL: URL) async throws -> [Float] {
        let (reader, output) = try await Self.makeReader(for: fileURL)

        guard reader.startReading() else {
            throw AudioDecoderError.decodingFailed(
                reader.error?.localizedDescription ?? "Unknown error starting AVAssetReader"
            )
        }

        var samples = [Float]()
        while let sampleBuffer = output.copyNextSampleBuffer() {
            try samples.append(contentsOf: Self.extractFloats(from: sampleBuffer))
        }

        guard reader.status == .completed else {
            throw AudioDecoderError.decodingFailed(
                reader.error?.localizedDescription ?? "AVAssetReader finished with status \(reader.status.rawValue)"
            )
        }

        return samples
    }

    // MARK: - Chunked Decode

    public func decodeChunked(
        fileURL: URL,
        chunkDuration: TimeInterval = 30.0,
        overlapDuration: TimeInterval = 1.0
    ) async throws -> AsyncThrowingStream<[Float], Error> {
        precondition(chunkDuration > 0, "chunkDuration must be positive")
        precondition(overlapDuration >= 0, "overlapDuration must be non-negative")
        precondition(overlapDuration < chunkDuration, "overlapDuration must be less than chunkDuration")

        let (reader, output) = try await Self.makeReader(for: fileURL)

        guard reader.startReading() else {
            throw AudioDecoderError.decodingFailed(
                reader.error?.localizedDescription ?? "Unknown error starting AVAssetReader"
            )
        }

        let chunkSamples = Int(chunkDuration * Self.targetSampleRate)
        let overlapSamples = Int(overlapDuration * Self.targetSampleRate)

        return AsyncThrowingStream { continuation in
            var buffer = [Float]()

            while let sampleBuffer = output.copyNextSampleBuffer() {
                do {
                    let floats = try Self.extractFloats(from: sampleBuffer)
                    buffer.append(contentsOf: floats)

                    while buffer.count >= chunkSamples {
                        let chunk = Array(buffer.prefix(chunkSamples))
                        continuation.yield(chunk)
                        buffer.removeFirst(chunkSamples - overlapSamples)
                    }
                } catch {
                    continuation.finish(throwing: error)
                    return
                }
            }

            if reader.status != .completed {
                continuation.finish(throwing: AudioDecoderError.decodingFailed(
                    reader.error?.localizedDescription ?? "AVAssetReader finished with status \(reader.status.rawValue)"
                ))
                return
            }

            if !buffer.isEmpty {
                continuation.yield(buffer)
            }

            continuation.finish()
        }
    }

    // MARK: - Private Static Helpers

    /// Creates an AVAssetReader configured for 16 kHz mono Float32 output.
    /// Static because it uses no actor state — only creates new AVFoundation objects.
    private static func makeReader(for fileURL: URL) async throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw AudioDecoderError.fileNotFound(fileURL.path)
        }

        let asset = AVURLAsset(url: fileURL)
        let tracks: [AVAssetTrack]
        do {
            tracks = try await asset.loadTracks(withMediaType: .audio)
        } catch {
            throw AudioDecoderError.unsupportedFormat(fileURL.path)
        }

        guard let audioTrack = tracks.first else {
            throw AudioDecoderError.noAudioTrack(fileURL.path)
        }

        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw AudioDecoderError.decodingFailed(error.localizedDescription)
        }

        let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: outputSettings)
        output.alwaysCopiesSampleData = false

        guard reader.canAdd(output) else {
            throw AudioDecoderError.unsupportedFormat(fileURL.path)
        }
        reader.add(output)

        return (reader, output)
    }

    /// Extracts Float32 samples from a CMSampleBuffer.
    /// Static because it's a pure transformation with no actor state.
    private static func extractFloats(from sampleBuffer: CMSampleBuffer) throws -> [Float] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return []
        }

        let length = CMBlockBufferGetDataLength(blockBuffer)
        let floatCount = length / MemoryLayout<Float>.size

        guard length > 0 else { return [] }

        // Allocate a properly Float-aligned buffer and copy directly
        // into it, avoiding Data's unspecified alignment guarantees.
        var floats = [Float](repeating: 0, count: floatCount)
        let status = floats.withUnsafeMutableBytes { rawPtr in
            CMBlockBufferCopyDataBytes(
                blockBuffer,
                atOffset: 0,
                dataLength: length,
                destination: rawPtr.baseAddress!
            )
        }

        guard status == kCMBlockBufferNoErr else {
            throw AudioDecoderError.decodingFailed("Failed to copy sample buffer data")
        }

        return floats
    }
}

// MARK: - Errors

public nonisolated enum AudioDecoderError: Error, CustomStringConvertible, Sendable {
    case fileNotFound(String)
    case noAudioTrack(String)
    case unsupportedFormat(String)
    case decodingFailed(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path):
            "File not found: \(path)"
        case .noAudioTrack(let path):
            "No audio track found in: \(path)"
        case .unsupportedFormat(let path):
            "Unsupported file format: \(path)"
        case .decodingFailed(let detail):
            "Audio decoding failed: \(detail)"
        }
    }
}
