//
//  main.swift
//  wispr-cli
//
//  Command-line tool for transcribing audio and video files using
//  on-device models managed by the Wispr GUI app.
//

import ArgumentParser
import Foundation

// MARK: - CLI Error Types

nonisolated enum CLIError: Error, CustomStringConvertible, Sendable {
    case noModelsDirectory
    case noDownloadedModels
    case noActiveModel
    case modelNotFound(String, available: [String])
    case fileNotFound(String)
    case noAudioTrack(String)
    case unsupportedFormat(String)
    case decodingFailed(String)
    case transcriptionFailed(String)

    var description: String {
        switch self {
        case .noModelsDirectory:
            "Wispr.app has not been set up yet. Please launch Wispr.app and download at least one model before using the CLI."
        case .noDownloadedModels:
            "No models downloaded. Please open Wispr.app and download at least one model, then try again. Run --list-models to verify."
        case .noActiveModel:
            "No active model set. Use --model <name> or select a model in Wispr.app. Run --list-models to see available models."
        case .modelNotFound(let name, let available):
            "Model '\(name)' not found. Available models: \(available.joined(separator: ", "))"
        case .fileNotFound(let path):
            "File not found: \(path)"
        case .noAudioTrack(let path):
            "No audio track found in: \(path)"
        case .unsupportedFormat(let path):
            "Unsupported file format: \(path)"
        case .decodingFailed(let detail):
            "Audio decoding failed: \(detail)"
        case .transcriptionFailed(let detail):
            "Transcription failed: \(detail)"
        }
    }
}

// MARK: - Supporting Types

nonisolated struct TranscribeConfig: Sendable {
    let filePath: String
    let modelName: String?
    let languageCode: String?
    let outputPath: String?
    let verbose: Bool
}

nonisolated struct DownloadedModelInfo: Sendable {
    let name: String
    let sizeOnDisk: Int64
    let path: URL
}

// MARK: - CLI Entry Point

@main
struct WisprCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wispr-cli",
        abstract: "Transcribe audio and video files using on-device models.",
        discussion: """
            Supported formats: MP3, WAV, M4A, FLAC, AAC, MP4, MOV

            Examples:
              wispr-cli recording.m4a
              wispr-cli meeting.mp4 --model large-v3 --language en
              wispr-cli podcast.mp3 --output transcript.txt --verbose
              wispr-cli --list-models
            """,
        version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    )

    @Argument(help: "Path to the audio or video file to transcribe.")
    var file: String?

    @Option(name: .long, help: "Model name to use for transcription.")
    var model: String?

    @Option(name: .long, help: "Language code for transcription (e.g., en, fr, ja).")
    var language: String?

    @Option(name: .long, help: "Write transcription to a file instead of stdout.")
    var output: String?

    @Flag(name: .long, help: "Print progress and timing information to stderr.")
    var verbose = false

    @Flag(name: .long, help: "List all downloaded models and exit.")
    var listModels = false

    mutating func run() async throws {
        if listModels {
            try doListModels()
        } else {
            guard let file else {
                throw ValidationError("Missing required argument: <file>")
            }
            try await transcribe(TranscribeConfig(
                filePath: file,
                modelName: model,
                languageCode: language,
                outputPath: output,
                verbose: verbose
            ))
        }
    }

    // MARK: - Transcription Orchestration

    func transcribe(_ config: TranscribeConfig) async throws {
        let fileURL = URL(fileURLWithPath: config.filePath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw CLIError.fileNotFound(config.filePath)
        }

        // 1. Resolve model
        let modelName = try resolveModel(config.modelName)
        if config.verbose {
            printStderr("Using model: \(modelName)")
        }

        // 2. Load model
        let engine = CompositeTranscriptionEngine(
            engines: [WhisperService(), ParakeetService()]
        )
        let startLoad = ContinuousClock.now
        try await engine.loadModel(modelName)
        if config.verbose {
            let elapsed = ContinuousClock.now - startLoad
            printStderr("Model loaded in \(elapsed)")
        }

        // 3. Get file metadata
        let decoder = AudioFileDecoder()
        let meta = try await decoder.metadata(for: fileURL)
        if config.verbose {
            printStderr("Audio duration: \(String(format: "%.1f", meta.duration))s")
        }

        // 4. Decode and transcribe
        let language: TranscriptionLanguage = config.languageCode
            .map { .specific(code: $0) } ?? .autoDetect

        if meta.duration <= 30.0 {
            // Short file — single-shot transcription
            let samples = try await decoder.decode(fileURL: fileURL)
            let result = try await engine.transcribe(samples, language: language)
            try writeOutput(result.text, to: config.outputPath)
        } else {
            // Long file — chunked transcription with overlap deduplication
            let chunks = try await decoder.decodeChunked(fileURL: fileURL)
            var chunkIndex = 0
            var previousText: String?
            var accumulated = ""

            for try await chunk in chunks {
                chunkIndex += 1
                if config.verbose {
                    printStderr("Transcribing chunk \(chunkIndex)...")
                }
                let result = try await engine.transcribe(chunk, language: language)
                if !result.text.isEmpty {
                    let text = deduplicateOverlap(
                        previous: previousText,
                        current: result.text
                    )
                    if !text.isEmpty {
                        if config.outputPath != nil {
                            accumulated += (accumulated.isEmpty ? "" : " ") + text
                        } else {
                            print(text)
                        }
                    }
                    previousText = result.text
                }
            }

            if let outputPath = config.outputPath {
                try accumulated.write(
                    toFile: outputPath,
                    atomically: true,
                    encoding: .utf8
                )
            }
        }
    }

    // MARK: - Model Discovery

    func resolveModel(_ explicitName: String?) throws -> String {
        let downloadedModels = try discoverDownloadedModels()
        guard !downloadedModels.isEmpty else {
            throw CLIError.noDownloadedModels
        }

        if let name = explicitName {
            guard downloadedModels.contains(where: { $0.name == name }) else {
                throw CLIError.modelNotFound(
                    name,
                    available: downloadedModels.map(\.name)
                )
            }
            return name
        }

        // Try GUI app's active model from UserDefaults
        if let active = UserDefaults.standard.string(forKey: "activeModelName"),
           downloadedModels.contains(where: { $0.name == active }) {
            return active
        }

        throw CLIError.noActiveModel
    }

    func discoverDownloadedModels() throws -> [DownloadedModelInfo] {
        let fm = FileManager.default
        let modelsDir = ModelPaths.models

        guard fm.fileExists(atPath: modelsDir.path) else {
            throw CLIError.noModelsDirectory
        }

        var results = [DownloadedModelInfo]()

        // Scan Whisper models: <models>/argmaxinc/whisperkit-coreml/<variant>/
        let whisperDir = ModelPaths.whisperModels
        if let variants = try? fm.contentsOfDirectory(atPath: whisperDir.path) {
            for variant in variants where !variant.hasPrefix(".") {
                let variantURL = whisperDir.appendingPathComponent(variant)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: variantURL.path, isDirectory: &isDir), isDir.boolValue {
                    // Extract model name from variant directory name
                    // e.g. "openai_whisper-large-v3" → "large-v3"
                    let modelName = extractWhisperModelName(from: variant)
                    let size = directorySize(at: variantURL)
                    results.append(DownloadedModelInfo(
                        name: modelName,
                        sizeOnDisk: size,
                        path: variantURL
                    ))
                }
            }
        }

        // Scan Parakeet models
        let parakeetEntries = [
            ("parakeet-v3", modelsDir.appendingPathComponent("parakeet-tdt-v3")),
            ("parakeet-eou-160ms", ModelPaths.parakeetEou)
        ]
        for (name, path) in parakeetEntries {
            if fm.fileExists(atPath: path.path) {
                let size = directorySize(at: path)
                results.append(DownloadedModelInfo(name: name, sizeOnDisk: size, path: path))
            }
        }

        return results
    }

    private func extractWhisperModelName(from variant: String) -> String {
        // WhisperKit variant directories are like "openai_whisper-large-v3"
        // Strip the "openai_whisper-" prefix to get the model name
        if let range = variant.range(of: "openai_whisper-") {
            return String(variant[range.upperBound...])
        }
        return variant
    }

    private func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - List Models

    func doListModels() throws {
        let models = try discoverDownloadedModels()
        if models.isEmpty {
            throw CLIError.noDownloadedModels
        }

        for model in models {
            let sizeMB = Double(model.sizeOnDisk) / 1_000_000
            print("\(model.name)\t\(String(format: "%.0f", sizeMB)) MB")
        }
    }

    // MARK: - Overlap Deduplication

    func deduplicateOverlap(previous: String?, current: String) -> String {
        guard let previous, !previous.isEmpty else { return current }

        let prevWords = previous.split(separator: " ")
        let currWords = current.split(separator: " ")
        let maxCompare = min(min(prevWords.count, currWords.count), 8)

        for length in stride(from: maxCompare, through: 1, by: -1) {
            let suffix = prevWords.suffix(length)
            let prefix = currWords.prefix(length)
            if suffix.elementsEqual(prefix, by: { $0.lowercased() == $1.lowercased() }) {
                return currWords.dropFirst(length).joined(separator: " ")
            }
        }
        return current
    }

    // MARK: - Output Helpers

    func printStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    private func writeOutput(_ text: String, to outputPath: String?) throws {
        if let outputPath {
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
