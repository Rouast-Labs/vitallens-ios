# VitalLens Core

The `VitalLensCore` module contains the pure logic, math, and data structures used by the library. It has no dependencies on `AVFoundation` or `UIKit`, making it safe to run on **macOS**, **watchOS**, or in **Server-Side Swift**.

## Signal Processing (`SignalOps`)

We expose our high-performance, vDSP-based signal processing engine publicly. You can use these primitives to analyze your own data arrays, even if they didn't come from the VitalLens API.

```swift
import VitalLensCore

let rawPPG: [Float] = ... // Your data

// 1. Preprocessing
// Detrend removes drift; Standardize performs Z-Score normalization
let cleanSignal = SignalOps.standardize(SignalOps.detrend(rawPPG, fs: 30.0))

// 2. Frequency Estimation
// Uses FFT to find dominant frequency within human bounds (40-240 BPM)
if let rate = SignalOps.estimateRate(from: cleanSignal, fs: 30.0, minRate: 40, maxRate: 240) {
    print("Estimated HR: \(rate)")
}

// 3. Peak Detection & HRV
// Uses adaptive thresholding to find peaks
let peaks = SignalOps.findPeaks(in: cleanSignal, fs: 30.0, hr: rate)

// Calculate metrics (SDNN, RMSSD)
if let sdnn = SignalOps.calculateSDNN(peaks: peaks, fs: 30.0) {
    print("SDNN: \(sdnn) ms")
}
```

## Inference Strategies

`vitallens-ios` is built using the **Strategy Pattern**. The camera logic (`StreamProcessor`) is decoupled from the estimation logic.

If you are an enterprise customer with a custom **CoreML** model, you can implement the `InferenceStrategy` protocol to run inference locally while keeping the rest of the pipeline (ROI tracking, buffering, HRV calculation) intact.

```swift
public protocol InferenceStrategy: Sendable {
    func resolveConfig() async throws -> ModelConfig
    func process(frames: Data, state: [Float]?, meta: [String: String]) async throws -> VitalLensResult
}
```

To use a custom strategy:

```swift
// Inject your custom strategy into the StreamProcessor
let myLocalStrategy = CoreMLStrategy(model: myLoadedModel)
let processor = StreamProcessor(strategy: myLocalStrategy)
```