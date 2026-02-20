# Contributing to vitallens-ios

This guide serves as a reference for developing, testing, and building the `vitallens-ios` SDK.

## 🛠 Development Setup

### Prerequisites

- **Xcode 15.0+** (Required for Swift 5.9 features)
- **iOS 15.0+** SDK
- **macOS 13.0+** (For running Core logic tests on Mac)

### Clone and Open

The project is configured as a standalone Swift Package.

```bash
# Clone the repo
git clone https://github.com/Rouast-Labs/vitallens-ios.git
cd vitallens-ios

# Open in Xcode
xed .
```

---

## 🏗 Building

You can build the library using the command line or Xcode.

### Command Line

```bash
# Build all targets
swift build

# Build specific target (e.g. Core logic)
swift build --target VitalLensInference
```

### Xcode

Simply select the `vitallens-ios` scheme and hit **Cmd + B**.

---

## 🧪 Running Tests

The test suite is split into logic tests (Core) and integration tests.

### VitalLensInference Tests (Logic)

These tests cover the signal processing, math, and buffering logic. They **do not** require a simulator and run natively on macOS.

```bash
# Run all tests
swift test

# Run specific test suite (e.g. VitalsEstimateManager)
swift test --filter VitalsEstimateManagerTests
```

### UI & Integration Tests

Tests involving `CameraSource` or `VitalLensUI` components must be run inside an iOS Simulator via Xcode.

1. Select the **vitallens-ios** scheme.
2. Select an iOS Simulator (e.g., iPhone 15 Pro).
3. Press **Cmd + U**.

> **Note:** `APIInference` uses a Mock URLProtocol, so it does not hit the real API. No API Key is required for standard testing.

---

## 🏛 Project Architecture

This repository is split into three distinct modules to ensure separation of concerns and testability.

| Module | Description | Dependencies |
| --- | --- | --- |
| **`VitalLensInference`** | **The Brain.** Pure logic, math (`Accelerate`), data structures, and the `InferenceStrategy` protocol. Runs on macOS/iOS. | None |
| **`VitalLens`** | **The Client.** Handles `AVCaptureSession`, Face Detection (Vision), and the `StreamProcessor` actor. Wires the Strategy to the Camera. | `VitalLensInference` |
| **`VitalLensUI`** | **The Views.** SwiftUI components (`ScanView`, `MonitorView`) and Charts. | `VitalLens` |

### Key Design Patterns

- **InferenceStrategy:** The `StreamProcessor` in `VitalLens` does not know about the API. It talks to an `InferenceStrategy`. This allows us to swap the API for a local CoreML model later.
- **Everything is an Array:** The `VitalLensResult` stores all data (heart rate, etc.) as `Waveform` arrays. We use `VitalRegistry` to decide how to derive scalar values (averaging vs FFT) from these arrays.

---

## 📦 Release Process

1. **Update Version:**

Update the version number in any documentation or `README.md` if hardcoded.

2. **Commit & Tag:**

SPM relies on Git tags for versioning.

```bash
git commit -am "Release 1.0.0"
git tag 1.0.0
git push origin main --tags
```

3. **Verify:**

Check that the tag is visible on GitHub. Clients using `from: "1.0.0"` will automatically pick up the new version.