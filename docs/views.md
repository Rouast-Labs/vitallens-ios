# SwiftUI Views (`VitalLensUI`)

`vitallens-ios` includes a set of pre-built SwiftUI views designed to get you up and running immediately. These components handle camera permissions, user guidance, and real-time visualization automatically.

## Setup

Ensure you import the UI module:

```swift
import VitalLensUI
```

## `VitalLensScanView`

A guided wizard that handles the entire measurement flow. It instructs the user to position their face, checks lighting conditions, and performs a fixed-duration measurement (default: 30 seconds).

**Best for:** Health check-ins, onboarding flows, spot checks.

```swift
VitalLensScanView(
    apiKey: "YOUR_KEY",
    method: .vitalLens2
) { result in
    print("Scan complete!")
}
```

### Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `apiKey` | `String` | Your VitalLens API Key. |
| `proxyURL` | `URL?` | URL to your backend proxy (Alternative to `apiKey`). |
| `method` | `Method` | Model version. Use `.vitalLens2` for HRV support. |
| `onComplete` | `(VitalLensResult) -> Void` | Callback triggered when the scan finishes successfully. |

---

## `VitalLensMonitorView`

A dashboard widget that visualizes live signals continuously. It renders a real-time PPG chart and displays numeric values as they update.

**Best for:** Wellness dashboards, meditation apps, fitness tracking.

```swift
VitalLensMonitorView(
    apiKey: "YOUR_KEY",
    showWaveforms: true // Set false to hide the graph
)
```

### Parameters

| Parameter | Type | Description |
| --- | --- | --- |
| `apiKey` | `String` | Your VitalLens API Key. |
| `proxyURL` | `URL?` | URL to your backend proxy. |
| `showWaveforms` | `Bool` | Whether to render the real-time PPG chart (default: `true`). |