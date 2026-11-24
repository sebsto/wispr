// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

// Swift settings matching the Xcode project configuration.
// All targets use MainActor default isolation (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor),
// Swift 6 language mode, and MemberImportVisibility.
let swiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
    .defaultIsolation(MainActor.self),
]

let package = Package(
    name: "wispr",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "0.17.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5"),
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.5.0"),
        .package(url: "https://github.com/soniqo/speech-swift.git", exact: "0.0.19"),
        .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.33.0"),
    ],
    targets: [
        // Shared types and transcription engines used by both the app and CLI.
        .target(
            name: "WisprCore",
            dependencies: [
                "WhisperKit",
                "FluidAudio",
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "MLX", package: "mlx-swift"),
            ],
            path: "Sources/WisprCore",
            swiftSettings: swiftSettings
        ),

        // macOS menu-bar app.
        .executableTarget(
            name: "WisprApp",
            dependencies: [
                "WisprCore",
                "WhisperKit",
                "FluidAudio",
            ],
            path: "Sources/WisprApp",
            exclude: ["Resources/Sounds", "Assets.xcassets"],
            swiftSettings: swiftSettings
        ),

        // Command-line transcription tool.
        .executableTarget(
            name: "WisprCLI",
            dependencies: [
                "WisprCore",
                "WhisperKit",
                "FluidAudio",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            path: "Sources/WisprCLI",
            swiftSettings: swiftSettings
        ),

        // Unit tests.
        .testTarget(
            name: "WisprTests",
            dependencies: ["WisprApp", "WisprCore", "WisprCLI"],
            path: "wisprTests",
            swiftSettings: swiftSettings
        ),
    ]
)
