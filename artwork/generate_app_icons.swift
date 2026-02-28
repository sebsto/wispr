#!/usr/bin/env swift
/// Generates all macOS app icon sizes from an SVG source and writes the Xcode asset catalog.
///
/// Usage: swift artwork/generate_app_icons.swift
///
/// Input:  artwork/icon.svg
/// Output: wispr/Assets.xcassets/AppIcon.appiconset/ (PNGs + Contents.json)
///
/// macOS app icons require these sizes (per Apple HIG):
///   16x16     @1x (16px)   @2x (32px)
///   32x32     @1x (32px)   @2x (64px)
///   128x128   @1x (128px)  @2x (256px)
///   256x256   @1x (256px)  @2x (512px)
///   512x512   @1x (512px)  @2x (1024px)

import AppKit
import Foundation

// MARK: - Configuration

let scriptDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let projectRoot = URL(fileURLWithPath: scriptDir).deletingLastPathComponent().path
let svgPath = "\(scriptDir)/icon.svg"
let outputDir = "\(projectRoot)/wispr/Assets.xcassets/AppIcon.appiconset"
let marginPercent: CGFloat = 0.02

/// All required macOS icon sizes: (point size, scale, pixel size)
let iconSizes: [(size: String, scale: String, pixels: Int)] = [
    ("16x16",   "1x",  16),
    ("16x16",   "2x",  32),
    ("32x32",   "1x",  32),
    ("32x32",   "2x",  64),
    ("128x128", "1x",  128),
    ("128x128", "2x",  256),
    ("256x256", "1x",  256),
    ("256x256", "2x",  512),
    ("512x512", "1x",  512),
    ("512x512", "2x",  1024),
]

// MARK: - SVG Loading

guard let svgData = FileManager.default.contents(atPath: svgPath) else {
    print("Error: Cannot read \(svgPath)")
    exit(1)
}

guard let svgImage = NSImage(data: svgData) else {
    print("Error: Could not parse SVG")
    exit(1)
}

// MARK: - Icon Rendering

func renderIcon(from source: NSImage, pixelSize: Int) -> NSBitmapImageRep? {
    let size = NSSize(width: pixelSize, height: pixelSize)

    guard let bitmapRep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelSize,
        pixelsHigh: pixelSize,
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

    // Clear to transparent
    context.cgContext.clear(CGRect(origin: .zero, size: size))

    // Draw with margin
    let margin = size.width * marginPercent
    let drawRect = NSRect(
        x: margin, y: margin,
        width: size.width - margin * 2,
        height: size.height - margin * 2
    )
    source.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

    NSGraphicsContext.restoreGraphicsState()
    return bitmapRep
}

// MARK: - Generate Icons

// Ensure output directory exists
try FileManager.default.createDirectory(
    atPath: outputDir,
    withIntermediateDirectories: true,
    attributes: nil
)

var contentsImages: [[String: String]] = []

for icon in iconSizes {
    let filename = "AppIcon-\(icon.size)@\(icon.scale).png"
    let filePath = "\(outputDir)/\(filename)"

    guard let bitmapRep = renderIcon(from: svgImage, pixelSize: icon.pixels) else {
        print("Error: Failed to render \(filename)")
        exit(1)
    }

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
        print("Error: Failed to create PNG for \(filename)")
        exit(1)
    }

    try pngData.write(to: URL(fileURLWithPath: filePath))
    print("  ✓ \(filename) (\(icon.size) @\(icon.scale))")

    contentsImages.append([
        "filename": filename,
        "idiom": "mac",
        "scale": icon.scale,
        "size": icon.size,
    ])
}

// MARK: - Write Contents.json

let contentsJSON: [String: Any] = [
    "images": contentsImages,
    "info": [
        "author": "xcode",
        "version": 1,
    ] as [String: Any],
]

let jsonData = try JSONSerialization.data(withJSONObject: contentsJSON, options: [.prettyPrinted, .sortedKeys])
let contentsPath = "\(outputDir)/Contents.json"
try jsonData.write(to: URL(fileURLWithPath: contentsPath))

print("\n✓ Generated \(iconSizes.count) icons + Contents.json in \(outputDir)")
