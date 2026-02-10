// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "vitallens-ios",
    platforms: [
        .iOS(.v15),
        .macOS(.v13)
    ],
    products: [
        .library(
            name: "VitalLens",
            targets: ["VitalLens", "VitalLensUI"]
        ),
        .library(
            name: "VitalLensCore",
            targets: ["VitalLensCore"]
        )
    ],
    targets: [
        // Core: Pure Logic (Networking, Math, State). No UI dependencies.
        .target(
            name: "VitalLensCore",
            dependencies: []
        ),
        
        // Lib: The Pipeline (Camera, Face Detection). Depends on Core.
        .target(
            name: "VitalLens",
            dependencies: ["VitalLensCore"]
        ),
        
        // UI: SwiftUI Components. Depends on Lib.
        .target(
            name: "VitalLensUI",
            dependencies: ["VitalLens"]
        ),
        
        // Core Logic Tests
        .testTarget(
            name: "VitalLensCoreTests",
            dependencies: ["VitalLensCore"]
        ),

        // Integration Tests (Runs on iOS Simulator)
        .testTarget(
            name: "VitalLensTests",
            dependencies: ["VitalLens", "VitalLensCore"],
            resources: [
                .copy("Resources/sample_video_2.mp4")
            ]
        ),

        .testTarget(
            name: "VitalLensUITests",
            dependencies: ["VitalLensUI", "VitalLens"]
        ),
    ]
)
