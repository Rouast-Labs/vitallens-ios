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
            name: "VitalLensInference",
            targets: ["VitalLensInference"]
        )
    ],
    targets: [
        // Inference: Pure Logic (Networking, Math, State). No UI dependencies.
        .target(
            name: "VitalLensInference",
            dependencies: []
        ),
        
        // Lib: The Pipeline (Camera, Face Detection). Depends on Core.
        .target(
            name: "VitalLens",
            dependencies: ["VitalLensInference"]
        ),
        
        // UI: SwiftUI Components. Depends on Lib.
        .target(
            name: "VitalLensUI",
            dependencies: ["VitalLens"]
        ),
        
        // Inference Logic Tests
        .testTarget(
            name: "VitalLensInferenceTests",
            dependencies: ["VitalLensInference"]
        ),

        // Integration Tests (Runs on iOS Simulator)
        .testTarget(
            name: "VitalLensTests",
            dependencies: ["VitalLens", "VitalLensInference"],
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
