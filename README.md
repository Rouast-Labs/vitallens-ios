# vitallens-ios

<div align="center">
<a href="https://www.rouast.com/api/">
<img src="https://raw.githubusercontent.com/Rouast-Labs/vitallens.js/main/assets/logo.svg" alt="VitalLens API Logo" height="80px" width="80px"/>
</a>

<strong>
Estimate vital signs such as heart rate, HRV, and respiratory rate from face video in Swift.
</strong>
</div>

`vitallens-ios` is the official Swift SDK for the **[VitalLens API](https://www.rouast.com/api/)**. It allows you to integrate physiological sensing into your iOS apps using just the device camera or existing video files.

> **Note:** This library is a "Pure API" client. It handles the complexity of face detection, video processing, and real-time streaming efficiency on-device, but the core estimation logic runs on the VitalLens Cloud API.

## Features

* **⚡️ Native Performance:** Built with Swift Concurrency (`async`/`await`), **Vision Framework**, and **Accelerate** for highly efficient, battery-friendly face detection and frame processing.
* **📱 Drop-in UI Components:** Ready-made SwiftUI views for 30-second scans or continuous monitoring.
* **🛠 Flexible Core API:** Full access to the raw data stream for building custom UIs.
* **📂 File Support:** Process pre-recorded videos from the Photo Library or local file system.
* **🔒 Privacy-First:** Face detection and cropping happen *on-device*. Only the cropped face region is sent to the API.

---

## Installation

### Swift Package Manager (SPM)

Add `vitallens-ios` to your project via Xcode:

1. Go to **File > Add Packages...**
2. Enter the repository URL: `https://github.com/Rouast-Labs/vitallens-ios.git`
3. Select **Up to Next Major Version** (e.g., `1.0.0`).

Import the module in your code:

```swift
import VitalLens

```

---

## Usage Guide

You can use VitalLens in two ways:

1. **Drop-in UI:** Use our pre-built SwiftUI views for instant integration.
2. **Core API:** Use `VitalLens` to build your own custom interface.

### Option 1: Drop-in UI Components

If you want a standard "Scan" or "Monitor" experience without writing camera code, use these SwiftUI components.

#### ⏱️ VitalLensScanView (30-second Scan)

A guided experience that prompts the user to position their face, performs a 30-second measurement, and returns the final result.

```swift
import SwiftUI
import VitalLens

struct MyScanScreen: View {
    @State private var scanResult: VitalLensResult?
    
    var body: some View {
        VitalLensScanView(
            apiKey: "YOUR_API_KEY",
            method: .vitalLens2 // Enables HRV
        ) { result in
            // Called when the 30-second scan is complete
            print("Heart Rate: \(result.vitalSigns.heartRate?.value ?? 0)")
            self.scanResult = result
        }
    }
}

```

#### 📈 VitalLensMonitorView (Continuous)

A continuous monitoring widget that shows live graphs and values. Useful for wellness dashboards or fitness tracking.

```swift
VitalLensMonitorView(
    apiKey: "YOUR_API_KEY",
    showWaveforms: true // Toggles real-time PPG chart
)

```

---

### Option 2: Core API (Custom UI)

Use the `VitalLens` controller to manage the camera and API connection.

```swift
// 1. Configure the client
let client = VitalLens(
    apiKey: "YOUR_API_KEY",
    method: .vitalLens2
)

// 2. Start the stream (inside an async context)
// 'previewView' is a standard UIView in your storyboard or SwiftUI wrapper
func startSession(in previewView: UIView) async {
    do {
        let stream = try await client.startStream(preview: previewView)
        
        for await result in stream {
            if let hr = result.vitalSigns.heartRate {
                print("Live HR: \(hr.value ?? 0) bpm")
            }
        }
    } catch {
        print("Stream error: \(error)")
    }
}

// 3. Stop the session
client.stopStream()

```

#### 3. Analyzing a Video File

You can also process existing video files (e.g., from the Camera Roll). This mimics the behavior of the API's `/file` endpoint but handles the chunking and uploading for you.

```swift
func analyzeVideo(url: URL) async {
    do {
        let result = try await client.processVideoFile(at: url)
        
        print("Average HR: \(result.vitalSigns.heartRate?.value ?? 0)")
        print("SDNN: \(result.vitalSigns.hrvSdnn?.value ?? 0) ms")
    } catch {
        print("Analysis failed: \(error)")
    }
}

```

---

## Configuration Options

When initializing `VitalLensController` or the UI components, you can pass a `VitalLensConfiguration` struct or individual parameters:

| Parameter | Type | Description | Default |
| --- | --- | --- | --- |
| `apiKey` | `String` | Your VitalLens API Key. | `nil` |
| `method` | `Method` | `.vitalLens` (Auto), `.vitalLens2` (HRV), etc. | `.vitalLens` |
| `faceDetectionFrequency` | `Double` | How often (Hz) to run the Vision face detector. | `1.0` |
| `proxyUrl` | `URL?` | Optional URL to your backend proxy (to hide API keys). | `nil` |

### Methods (`VitalLens.Method`)

* `.vitalLens` (Recommended): Automatically selects the best model for your plan.
* `.vitalLens2`: Forces VitalLens 2.0 (High accuracy, HRV supported).
* `.vitalLens1`: Forces VitalLens 1.0 (Standard accuracy).

---

## Requirements

* **iOS 15.0+**
* **Camera Permission:** You must add `NSCameraUsageDescription` to your app's `Info.plist` to use the live scanning features.

## Security & Best Practices

### API Keys

Avoid hardcoding your API key in your shipping app.

* **Recommended:** Use a backend proxy. Set `proxyUrl` in the `VitalLensController` configuration to point to your server. Your server adds the `x-api-key` header and forwards the request to `https://api.rouast.com`.

### Privacy

* **On-Device Processing:** This library uses Apple's **Vision Framework** to detect faces locally on the device.
* **Data Minimization:** Only the cropped region of interest (ROI) containing the face is transmitted to the API. Full-frame video is never uploaded.

## Advanced: Signal Processing Utilities

`vitallens-ios` exposes its high-performance, vDSP-based signal processing engine via `SignalOps`. This allows you to perform physiological signal analysis on your own data arrays (e.g. from local inference models or other sources) without using the API client.

All methods are stateless and use Apple's **Accelerate** framework for efficiency.

### Available Primitives

```swift
import VitalLens

// 1. Preprocessing
let cleanSignal = SignalOps.detrend(rawPPG, fs: 30.0)
let standardized = SignalOps.standardize(cleanSignal)

// 2. Heart Rate Estimation (FFT)
if let heartRate = SignalOps.estimateRate(from: cleanSignal, fs: 30.0, minRate: 40, maxRate: 240) {
    print("HR: \(heartRate) bpm")
}

// 3. HRV Analysis
// Detect peaks using adaptive Z-score thresholding
let peaks = SignalOps.findPeaks(in: cleanSignal, fs: 30.0, hr: heartRate)

// Calculate metrics
if let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: 30.0) {
    print("SDNN: \(sdnn) ms")
}

## License

MIT License. See [LICENSE](https://www.google.com/search?q=LICENSE) for details.