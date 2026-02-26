// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "vitallens-ios",
    platforms: [
        .iOS(.v16),
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
    ],
     dependencies: [
        .package(url: "https://github.com/Rouast-Labs/vitallens-core.git", exact: "0.1.0")
    ],
    targets: [
        // Inference: Pure Logic (Networking, State). No UI dependencies.
        .target(
            name: "VitalLensInference",
            dependencies: [
                .product(name: "VitalLensCore", package: "vitallens-core")
            ]
        ),
        
        // Lib: The Pipeline (Camera, Face Detection). Depends on Core.
        .target(
            name: "VitalLens",
            dependencies: [
                "VitalLensInference", 
                .product(name: "VitalLensCore", package: "vitallens-core")
            ]
        ),
        
        // UI: SwiftUI Components. Depends on Lib.
        .target(
            name: "VitalLensUI",
            dependencies: ["VitalLens"],
            resources: [
                .process("Assets.xcassets")
            ]
        ),
        
        // Inference Logic Tests
        .testTarget(
            name: "VitalLensInferenceTests",
            dependencies: [
                "VitalLensInference", 
                .product(name: "VitalLensCore", package: "vitallens-core")
            ]
        ),

        // Integration Tests (Runs on iOS Simulator)
        .testTarget(
            name: "VitalLensTests",
            dependencies: [
                "VitalLens", 
                "VitalLensInference", 
                .product(name: "VitalLensCore", package: "vitallens-core")
            ],
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
