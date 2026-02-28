#!/usr/bin/env swift
/// Resizes a large PNG to standard macOS screenshot sizes.
///
/// Usage: swift artwork/generate_screenshots.swift <input.png> [output_dir]
///
/// Input:  A large PNG file
/// Output: 1280x800 and 1440x900 variants in the output directory (defaults to artwork/screenshots)

import AppKit
import Foundation

// MARK: - Configuration

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let sizes: [(width: Int, height: Int)] = [
    (1280, 800),
    (1440, 900),
]

// MARK: - Arguments

let args = CommandLine.arguments
guard args.count >= 2 else {
    print("Usage: swift \(args[0]) <input.png> [output_dir]")
    exit(1)
}

let inputPath = args[1]
let outputDir = args.count >= 3 ? args[2] : "\(scriptDir)/screenshots"

// MARK: - Load Source Image

guard let imageData = FileManager.default.contents(atPath: inputPath) else {
    print("Error: Cannot read \(inputPath)")
    exit(1)
}

guard let sourceImage = NSImage(data: imageData) else {
    print("Error: Could not parse image")
    exit(1)
}

// MARK: - Resize

func resize(source: NSImage, width: Int, height: Int) -> NSBitmapImageRep? {
    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let drawRect = NSRect(x: 0, y: 0, width: width, height: height)
    source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return bitmapRep
}

// MARK: - Generate

try FileManager.default.createDirectory(
    atPath: outputDir,
    withIntermediateDirectories: true,
    attributes: nil
)

let baseName = URL(fileURLWithPath: inputPath).deletingPathExtension().lastPathComponent

for size in sizes {
    let filename = "\(baseName)-\(size.width)x\(size.height).png"
    let filePath = "\(outputDir)/\(filename)"

    guard let bitmapRep = resize(source: sourceImage, width: size.width, height: size.height) else {
        print("Error: Failed to resize to \(size.width)x\(size.height)")
        exit(1)
    }

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Error: Failed to create PNG for \(filename)")
        exit(1)
    }

    try pngData.write(to: URL(fileURLWithPath: filePath))
    print("  ✓ \(filename) (\(size.width)x\(size.height))")
}

print("\n✓ Generated \(sizes.count) screenshots in \(outputDir)")
