# Contributing & Development Guide

This guide covers how to set up, test, and build the `vitallens-ios` SDK.

## Prerequisites

- **Xcode 15.0+**
- **iOS 16.0+** SDK
- **macOS 13.0+** (For running core logic tests natively on Mac)

## Development Setup

The project is a standalone Swift Package. To get started:

```bash
# Clone the repo
git clone https://github.com/Rouast-Labs/vitallens-ios.git
cd vitallens-ios

# Open in Xcode
xed .
```

## Building

You can build the library using Xcode (select the `vitallens-ios` scheme and hit **Cmd + B**) or via the command line:

```bash
# Build all targets
swift build

# Build a specific target
swift build --target VitalLensInference
```

## Testing

The test suite is split into logic tests and integration/UI tests. **Not all tests can run via the command line.**

### Logic Tests (Command Line)

Tests for the core signal processing, math, and buffering (`VitalLensInferenceTests`) do not require a simulator and run natively on macOS.

```bash
swift test
```

### UI & Camera Tests (Xcode Simulator)

Tests involving `CameraSource` or `VitalLensUI` components **must** be run inside an iOS Simulator via Xcode.

In Xcode:

1. Select the **vitallens-ios** scheme.
2. Select an iOS Simulator (e.g., iPhone 15 Pro).
3. Press **Cmd + U**.

Or you can run:

```
xcodebuild test \
    -scheme vitallens-ios-Package \
    -destination "platform=iOS Simulator,name=iPhone Air,OS=latest"
```

### API Integration Tests

Some integration tests make real network calls to the VitalLens API. To run these successfully, you must provide your API key via environment variables in your Xcode scheme:

1. Edit the `vitallens-ios` scheme in Xcode.
2. Go to the **Test** action > **Arguments** tab.
3. Under **Environment Variables**, add:
    * `VITALLENS_API_KEY`: Your actual API key.
    * `VITALLENS_BASE_URL`: (Optional) Overrides the default API URL if you are testing against a proxy or staging environment.

## Release Process

We rely on Git tags for Swift Package Manager versioning. A GitHub Action is configured to automatically create a GitHub Release and generate a changelog whenever a new semantic version tag is pushed.

The SDK also sends its version to the API as part of the origin (`vitallens-ios_<version>`), taken from `VitalLensVersion.current` in `Sources/VitalLensInference/VitalLensVersion.swift`. SwiftPM cannot read the tag at build time, so the constant has to match the tag. The release script sets it for you, and the release workflow fails if the two ever differ.

To cut a new release:

1. **Get your changes into `main`** (merge your `dev` PR on GitHub).

2. **Create the version commit and tag on `main`:**
    ```bash
    git switch main
    git pull origin main
    ./scripts/release.sh 0.2.1
    ```
    This sets `VitalLensVersion.current` and the version in the README install snippet, commits them as `0.2.1` and creates the tag `v0.2.1`. Nothing is pushed yet. It refuses to run unless you are on an up-to-date `main` with a clean working tree.

3. **Push the commit and the tag:**
    ```bash
    git push origin main --follow-tags
    ```

4. **Sync `dev`:**
    ```bash
    git switch dev
    git merge main
    git push origin dev
    ```


## User-facing wording

The on-screen feedback messages (Start screen guide, status and issue messages in the Scan and Monitor views) are kept mostly consistent across the JS, iOS and Android SDKs, and match the guidance on the [Accuracy & Guidelines](https://docs.rouast.com/guides/accuracy/) page. When you change any of them, update the other SDKs too (and their tests), or at least keep the wording close.
