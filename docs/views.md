# SwiftUI Views

The `VitalLensUI` module provides pre-built SwiftUI components to get you up and running quickly. These views handle camera permissions, state management, user guidance, and data visualization.

## Setup

Import the UI module in your SwiftUI files:

```swift
import VitalLensUI
```

---

## 1. VitalLensScanView

A guided flow that handles a full measurement cycle. It instructs the user to position their face, checks lighting conditions, performs a ~30-second scan, and displays the final results.

```swift
VitalLensScanView(
    apiKey: "YOUR_KEY",
    method: "vitallens",
    mode: .eco
) { result in
    if let hr = result.heartRate?.value {
        print("Final Heart Rate: \(hr) bpm")
    }
}
```

### Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `apiKey` | `String?` | Your API Key. Required if `proxyURL` is not set. |
| `proxyURL` | `URL?` | URL to your backend proxy. |
| `method` | `String` | Model version (e.g., `"vitallens"`, `"vitallens-2.0"`). Default is `"vitallens"`. |
| `mode` | `VitalLensMode` | `.eco` (15 FPS, default) or `.standard` (30 FPS). |
| `onComplete` | `(VitalLensResult) -> Void` | Callback triggered when the scan finishes successfully. |

---

## 2. VitalLensMonitorView

A dashboard widget that visualizes live signals continuously. It renders real-time PPG and respiratory charts, displaying numeric values as they update.

```swift
VitalLensMonitorView(
    apiKey: "YOUR_KEY",
    showWaveforms: true
)
```

### Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `apiKey` | `String?` | Your API Key. Required if `proxyURL` is not set. |
| `proxyURL` | `URL?` | URL to your backend proxy. |
| `method` | `String` | Model version. Default is `"vitallens"`. |
| `showWaveforms` | `Bool` | Whether to render the real-time waveform charts. Default is `true`. |
| `initialMode` | `VitalLensMode` | Initial FPS mode `.eco` or `.standard`. Default is `.eco`. |
| `bufferOffset` | `TimeInterval` | Delay in seconds for smooth chart rendering. Default is `0.15`. |
| `windowSize` | `TimeInterval` | Duration of data to show in the waveform charts. Default is `8.0`. |
| `minDisplayDuration` | `TimeInterval` | Minimum data required before displaying values. Default is `6.0`. |

---

## 3. VitalLensFileView

A complete UI for selecting and analyzing pre-recorded videos from the user's Photo Library or Files app. It handles file selection, extraction, processing, and result visualization.

```swift
VitalLensFileView(
    apiKey: "YOUR_KEY"
)
```

### Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `apiKey` | `String?` | Your API Key. Required if `proxyURL` is not set. |
| `proxyURL` | `URL?` | URL to your backend proxy. |
| `method` | `String` | Model version. Default is `"vitallens"`. |
