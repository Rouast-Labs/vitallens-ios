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
        ),
        .library(
            name: "VitalLensCore",
            targets: ["VitalLensCore"]
        )
    ],
    targets: [
        // The Precompiled Rust Binary
        .binaryTarget(
            name: "VitalLensCoreFFI", 
            path: "Frameworks/VitalLensCoreFFI.xcframework"
        ),

        // The Swift Wrapper for the Rust Core
        .target(
            name: "VitalLensCore",
            dependencies: ["VitalLensCoreFFI"],
            path: "Sources/VitalLensCore",
            swiftSettings: [
                .swiftLanguageMode(.v5) 
            ]
        ),

        // Inference: Pure Logic (Networking, State). No UI dependencies.
        .target(
            name: "VitalLensInference",
            dependencies: ["VitalLensCore"]
        ),
        
        // Lib: The Pipeline (Camera, Face Detection). Depends on Core.
        .target(
            name: "VitalLens",
            dependencies: ["VitalLensInference", "VitalLensCore"]
        ),
        
        // UI: SwiftUI Components. Depends on Lib.
        .target(
            name: "VitalLensUI",
            dependencies: ["VitalLens"]
        ),
        
        // Inference Logic Tests
        .testTarget(
            name: "VitalLensInferenceTests",
            dependencies: ["VitalLensInference", "VitalLensCore"]
        ),

        // Integration Tests (Runs on iOS Simulator)
        .testTarget(
            name: "VitalLensTests",
            dependencies: ["VitalLens", "VitalLensInference", "VitalLensCore"],
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
