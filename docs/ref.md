# API Reference

The `VitalLens` class is the main entry point for the SDK. You should use this class directly if you are building a custom camera experience, integrating into an existing `AVCaptureSession`, or processing video files in the background without using the pre-built SwiftUI views.

## Initialization

The `VitalLens` client initializer allows you to start with simple defaults or inject custom components for advanced integrations.

```swift
public init(
    apiKey: String? = nil,
    method: String = "vitallens",
    faceDetectionFrequency: Double = 1.0,
    globalROI: CGRect? = nil,
    proxyURL: URL? = nil,
    overrideFps: Double? = nil,
    waveformMode: WaveformMode = .incremental,
    debugMode: Bool = false,
    source: (any CameraStreaming)? = nil,
    strategy: (any InferenceStrategy)? = nil,
    transformer: FrameTransformer? = nil
)
```

### Parameters

| Name | Type | Description | Default |
| --- | --- | --- | --- |
| `apiKey` | `String?` | Your API Key. Required if `proxyURL` and `strategy` are not set. | `nil` |
| `method` | `String` | The model version to use (e.g., `"vitallens"`, `"vitallens-2.0"`). | `"vitallens"` |
| `proxyURL` | `URL?` | URL to a backend proxy (Recommended for production). | `nil` |
| `faceDetectionFrequency` | `Double` | Frequency (Hz) to run face detection. Lower values save battery. | `1.0` |
| `globalROI` | `CGRect?` | A fixed ROI (normalized `0.0`-`1.0`) to bypass face detection. | `nil` |
| `overrideFps` | `Double?` | Target sampling FPS. Overrides model default if set. | `nil` |
| `waveformMode` | `WaveformMode` | Waveform return mode: `.incremental` or `.global`. | `.incremental` |
| `debugMode` | `Bool` | If `true`, exposes intermediate frame crops for debugging. | `false` |
| `source` | `CameraStreaming?` | A custom frame source. Defaults to standard `CameraSource`. | `nil` |
| `strategy` | `InferenceStrategy?` | A custom inference backend (e.g., CoreML). Defaults to `APIInference`. | `nil` |
| `transformer` | `FrameTransformer?` | A custom closure to preprocess frames before inference. | `nil` |

### Configuration Logic

The SDK intelligently configures itself based on the parameters you provide:

1. **Inference Strategy:** If you provide a `strategy`, the SDK uses it directly. If `strategy` is `nil`, the SDK initializes an `APIInference` strategy using your `apiKey` or `proxyURL`.
2. **Camera Source:** If you provide a `source` (such as a `PassiveSource` for external camera frames), the SDK uses it. Otherwise, it initializes a standard `CameraSource` to manage the device hardware.

### Method Options

When using the default API `InferenceStrategy`, these options are available for `method`:

- `"vitallens"`: **(Recommended)** Uses the VitalLens API and automatically selects the best model available for your API key (e.g., VitalLens 2.0 with HRV support).
- `"vitallens-2.0"`: Forces the use of the VitalLens 2.0 model.
- `"vitallens-1.0"` / `"vitallens-1.1"`: Forces the use of older model versions.

### Examples

**Standard API Integration:**

```swift
let client = VitalLens(apiKey: "YOUR_KEY")
```

**Custom Camera with API Inference:**

```swift
let client = VitalLens(
    apiKey: "YOUR_KEY", 
    source: myPassiveSource
)
```

**Local CoreML Integration:**

```swift
let client = VitalLens(
    strategy: MyCoreMLStrategy()
)
```

---

## Properties

### `onFaceStateChanged`

A closure triggered instantly when the face detector either finds a face or loses tracking. Useful for updating user guidance UI (e.g., "Please face the camera").

```swift
client.onFaceStateChanged = { isPresent in
    if isPresent {
        print("Face detected!")
    } else {
        print("Face lost. Adjust position.")
    }
}
```

---

## Methods

### `startStream(preview:)`

Starts the device camera, manages the processing loop, and yields results continuously via a Swift `AsyncStream`.

**Parameters:**

- `preview`: (Optional) A `UIView` where the live camera feed will be rendered using an `AVCaptureVideoPreviewLayer`.

**Returns:** `AsyncStream<VitalLensResult>`

```swift
Task {
    do {
        let stream = try await client.startStream(preview: myPreviewView)
        for await result in stream {
            if let hr = result.heartRate?.value {
                print("Live HR: \(hr)")
            }
        }
    } catch {
        print("Failed to start stream: \(error)")
    }
}
```

### `stopStream()`

Stops the active camera session, terminates the background inference loop, and clears internal data buffers.

```swift
client.stopStream()
```

### `resetStream()`

Clears the internal data buffers (PPG history, face tracking state) without stopping the camera. Call this if the user moves drastically and you want to force a fresh estimation window.

```swift
client.resetStream()
```

### `processVideoFile(at:)`

Processes a local video file in batch mode. Automatically extracts frames, detects the most prominent face, and communicates with the API.

**Parameters:**

- `url`: The local `URL` of the video file (e.g., `.mp4` or `.mov`).

**Returns:** `VitalLensResult`

```swift
do {
    let result = try await client.processVideoFile(at: videoURL)
    print("Avg HR: \(result.heartRate?.value ?? 0)")
} catch {
    print("File processing failed: \(error)")
}
```

---

## Advanced Initialization (Custom CoreML / Camera)

If you have an Enterprise plan with a custom CoreML model, or if you manage your own `AVCaptureSession`, you can inject your own strategies into the client:

```swift
init(
    source: any CameraStreaming,
    strategy: any InferenceStrategy,
    transformer: FrameTransformer? = nil,
    waveformMode: WaveformMode = .incremental,
    debugMode: Bool = false
)
```

See the **[Advanced](advanced.md)** documentation for details on implementing `InferenceStrategy`.

---

## Data Models

### `VitalLensResult`

The data structure returned by the SDK. All physiological data is represented as arrays matching the frame count, with convenient scalar accessors.

| Property | Type | Description |
| --- | --- | --- |
| `face` | `FaceData` | Bounding boxes and confidence of detected faces. |
| `vitals` | `[String: Vital]` | Raw dictionary of all returned scalar signals. |
| `waveforms` | `[String: Waveform]` | Raw dictionary of all returned time-series signals. |
| `time` | `[Double]` | Array of capture timestamps for the returned data. |
| `fps` | `Double?` | The actual frames per second processed. |
| `message` | `String?` | Status message from the inference engine. |

**Convenience Accessors:**
Instead of looking up string keys in dictionaries, you can use these strongly-typed properties:

- `heartRate: Vital?`
- `respiratoryRate: Vital?`
- `hrvSdnn: Vital?`
- `hrvRmssd: Vital?`
- `ppg: Waveform?`
- `resp: Waveform?`

### `Vital`

Represents a scalar physiological estimation.

| Property | Type | Description |
| --- | --- | --- |
| `value` | `Double` | The estimated value (e.g., `72.0`). |
| `confidence` | `Double` | Estimation confidence from `0.0` to `1.0`. |
| `unit` | `String` | The unit of measurement (e.g., `"bpm"`, `"ms"`). |

### `Waveform`

Represents a continuous signal over time.

| Property | Type | Description |
| --- | --- | --- |
| `data` | `[Float]` | The raw signal array. |
| `confidence` | `[Float]` | Confidence array (`0.0`-`1.0`) mapping to each point in `data`. |
| `unit` | `String?` | The unit of the signal (often unitless for PPG). |

### `FaceData`

Details about the face tracking during the measurement window.

| Property | Type | Description |
| --- | --- | --- |
| `boundingBoxes` | `[CGRect]` | Normalized (`0.0`-`1.0`) tracking boxes for each frame. |
| `confidence` | `[Double]?` | Confidence array (`0.0`-`1.0`) of the face detection for each frame. |
