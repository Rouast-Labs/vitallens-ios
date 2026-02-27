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

To cut a new release:

1. **Tag the release:**
    ```bash
    git tag 0.1.0
    ```

2. **Push the tag:**
    ```bash
    git push origin 0.1.0
    ```