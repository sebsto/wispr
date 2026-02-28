#!/usr/bin/env swift
/// Renders an SVG to a 1024x1024 PNG with transparent background using macOS native APIs.
/// Usage: swift svg_to_png.swift icon.svg AppIcon-1024x1024.png

import AppKit
import Foundation

guard CommandLine.arguments.count >= 3 else {
    print("Usage: swift svg_to_png.swift <input.svg> <output.png>")
    exit(1)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let svgData = FileManager.default.contents(atPath: inputPath) else {
    print("Error: Cannot read \(inputPath)")
    exit(1)
}

// Parse SVG to get the viewBox for proper bounds
guard let svgString = String(data: svgData, encoding: .utf8) else {
    print("Error: Invalid SVG encoding")
    exit(1)
}

// Use NSImage which supports SVG natively on macOS
guard let svgImage = NSImage(data: svgData) else {
    print("Error: Could not parse SVG")
    exit(1)
}

let targetSize = NSSize(width: 1024, height: 1024)

// Create a bitmap with transparent background
guard let bitmapRep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(targetSize.width),
    pixelsHigh: Int(targetSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    print("Error: Could not create bitmap")
    exit(1)
}

// Draw SVG into bitmap
NSGraphicsContext.saveGraphicsState()
guard let context = NSGraphicsContext(bitmapImageRep: bitmapRep) else {
    print("Error: Could not create graphics context")
    exit(1)
}
NSGraphicsContext.current = context

// Clear to transparent
context.cgContext.clear(CGRect(origin: .zero, size: targetSize))

// Calculate content bounds and draw with maxrgin
let marginPercentage = 0.0
let margin: CGFloat = targetSize.width * marginPercentage
let drawSize = NSSize(width: targetSize.width - margin * 2, height: targetSize.height - margin * 2)
let drawRect = NSRect(x: margin, y: margin, width: drawSize.width, height: drawSize.height)

svgImage.draw(in: drawRect, from: .zero, operation: .sourceOver, fraction: 1.0)

NSGraphicsContext.restoreGraphicsState()

// Save as PNG
guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else {
    print("Error: Could not create PNG data")
    exit(1)
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
    print("Saved \(outputPath) (1024x1024, transparent background)")
} catch {
    print("Error writing file: \(error)")
    exit(1)
}
