//
//  main.swift
//  wispr-cli
//
//  Command-line tool for transcribing audio and video files using
//  on-device models managed by the Wispr GUI app.
//

import ArgumentParser
import Foundation
import WisprCore

// MARK: - CLI Error Types

enum CLIError: Error, CustomStringConvertible, Sendable {
    case noModelsDirectory
    case noDownloadedModels
    case noActiveModel
    case modelNotFound(String, available: [String])
    case fileNotFound(String)

    // nonisolated because ArgumentParser accesses error descriptions
    // outside MainActor when formatting CLI error output.
    nonisolated var description: String {
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
        }
    }
}

// MARK: - Supporting Types

struct TranscribeConfig: Sendable {
    let filePath: String
    let modelName: String?
    let languageCode: String?
    let outputPath: String?
    let verbose: Bool
}

struct DownloadedModelInfo: Sendable {
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
        printStderr("Using model: \(modelName)")

        // Suppress FluidAudio SDK logs unless --verbose is set.
        // The SDK writes INFO-level messages to stderr with no public
        // log-level filter, so we redirect the fd during engine calls.
        let savedFd = config.verbose ? Int32(-1) : suppressStderr()
        defer { if !config.verbose { restoreStderr(savedFd) } }

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
        // Decode the full audio and let the transcription engine handle its
        // own chunking strategy. Both WhisperKit and Parakeet have built-in
        // chunk processors with proper overlap, context windows, and token
        // deduplication that produce significantly better results than naive
        // external chunking.
        let language: TranscriptionLanguage = config.languageCode
            .map { .specific(code: $0) } ?? .autoDetect

        let samples = try await decoder.decode(fileURL: fileURL)
        if config.verbose {
            printStderr("Decoded \(samples.count) samples")
        }

        let result = try await engine.transcribe(samples, language: language)
        try writeOutput(result.text, to: config.outputPath)
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

        // Try GUI app's active model from its sandboxed container plist.
        if let active = guiDefaultsString(forKey: "activeModelName"),
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

        // Scan Parakeet V3 models: directories matching "parakeet-tdt-*-v3*"
        // The SDK leaf name varies by FluidAudio version (e.g. "parakeet-tdt-0.6b-v3").
        if let entries = try? fm.contentsOfDirectory(atPath: modelsDir.path) {
            for entry in entries where entry.hasPrefix("parakeet-tdt-") && entry.contains("v3") {
                let entryURL = modelsDir.appendingPathComponent(entry)
                var isDir: ObjCBool = false
                if fm.fileExists(atPath: entryURL.path, isDirectory: &isDir), isDir.boolValue {
                    let size = directorySize(at: entryURL)
                    results.append(DownloadedModelInfo(
                        name: "parakeet-v3",
                        sizeOnDisk: size,
                        path: entryURL
                    ))
                    break // Only one V3 model
                }
            }
        }

        // Scan Parakeet EOU model
        let eouPath = ModelPaths.parakeetEou
        if fm.fileExists(atPath: eouPath.path) {
            let size = directorySize(at: eouPath)
            results.append(DownloadedModelInfo(name: "parakeet-eou-160ms", sizeOnDisk: size, path: eouPath))
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

        let activeModel = guiDefaultsString(forKey: "activeModelName")

        for model in models {
            let sizeMB = Double(model.sizeOnDisk) / 1_000_000
            let active = model.name == activeModel ? " (active)" : ""
            print("\(model.name)\t\(String(format: "%.0f", sizeMB)) MB\(active)")
        }
    }

    // MARK: - GUI Defaults

    /// Reads a string value from the GUI app's UserDefaults plist.
    /// Uses `ModelPaths.guiDefaultsPlist` which resolves to the sandboxed
    /// container plist when running outside the sandbox (CLI).
    private func guiDefaultsString(forKey key: String) -> String? {
        guard let data = try? Data(contentsOf: ModelPaths.guiDefaultsPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return plist[key] as? String
    }

    // MARK: - Output Helpers

    func printStderr(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    /// Redirects stderr to /dev/null to suppress third-party SDK logging.
    /// Returns the saved file descriptor to pass to `restoreStderr`.
    @discardableResult
    private func suppressStderr() -> Int32 {
        let saved = dup(STDERR_FILENO)
        let devNull = open("/dev/null", O_WRONLY)
        if devNull >= 0 {
            dup2(devNull, STDERR_FILENO)
            close(devNull)
        }
        return saved
    }

    /// Restores stderr from a previously saved file descriptor.
    private func restoreStderr(_ saved: Int32) {
        guard saved >= 0 else { return }
        dup2(saved, STDERR_FILENO)
        close(saved)
    }

    private func writeOutput(_ text: String, to outputPath: String?) throws {
        if let outputPath {
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
        } else {
            print(text)
        }
    }
}
