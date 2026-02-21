# vitallens-ios

<div align="center">
  <a href="https://www.rouast.com/api/">
    <img src="https://raw.githubusercontent.com/Rouast-Labs/vitallens.js/main/assets/logo.svg" alt="VitalLens API Logo" height="80px" width="80px"/>
  </a>
  <h3>VitalLens API Client for iOS</h3>
  <p>Estimate vital signs such as heart rate, HRV, and respiratory rate from face video in Swift.</p>
</div>

<!-- mkdocs-start -->
`vitallens-ios` is the official Swift SDK for the **[VitalLens API](https://www.rouast.com/api/)**. It provides a modular, high-performance toolset for integrating physiological sensing into iOS applications using `async`/`await` and the Vision framework.

## Features

- **⚡️ Native Performance:** Uses **Accelerate (vDSP)** for efficient on-device signal processing.
- **📱 Drop-in UI:** Ready-made SwiftUI views (`VitalLensUI`) for instant scanning or monitoring.
- **🔌 Pluggable Inference:** Built on the `InferenceStrategy` pattern, allowing you to swap backends (Remote API vs. Local CoreML) easily.
- **🔒 Privacy-First:** Face detection and cropping happen *on-device*. Full-frame video is never streamed to the cloud.

## Installation

### Swift Package Manager

Add the package via Xcode or your `Package.swift`:

1. **Repository URL:** `https://github.com/Rouast-Labs/vitallens-ios.git`
2. **Version:** Up to Next Major (e.g., `1.0.0`)

Select the targets you need:

- `VitalLens`: Main client logic.
- `VitalLensUI`: Pre-built SwiftUI views (Recommended).
- `VitalLensInference`: Pure logic/math (No Camera dependencies).

## Quickstart

The fastest way to get started is using the **30-second Scan** component.

```swift
import SwiftUI
import VitalLens
import VitalLensUI

struct ScanView: View {
    var body: some View {
        VitalLensScanView(
            apiKey: "YOUR_API_KEY",
            method: "vitallens-2.0"
        ) { result in
            // Handle results (e.g., save to HealthKit)
            if let hr = result.heartRate?.latest?.value {
                print("Heart Rate: \(hr) bpm")
            }
        }
    }
}
```
<!-- mkdocs-end -->

## Documentation

- **[SwiftUI Views](https://docs.rouast.com/ios/views):** Drop-in SwiftUI views for scanning and monitoring.
- **[Examples](https://docs.rouast.com/ios/examples):** How to analyze files or build custom camera loops.
- **[Core & Advanced](https://docs.rouast.com/ios/core):** Using `SignalOps`, `InferenceStrategy`, and math utilities directly.
- **[Proxies & Security](https://docs.rouast.com/ios/proxies):** How to keep your API keys safe.
- **[API Reference](https://docs.rouast.com/ios/ref):** Detailed class and method documentation.

<!-- mkdocs-bottom-start -->
## Requirements

* **iOS 15.0+**
* **macOS 13.0+** (Core only)
* **Camera Permission:** Add `NSCameraUsageDescription` to your `Info.plist`.

## License

MIT License. See [LICENSE](LICENSE) for details.
<!-- mkdocs-bottom-end -->
