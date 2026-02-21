# API Reference

## `VitalLens`

The main entry point for the SDK.

### Initializer

```swift
init(
    apiKey: String? = nil,
    method: Method = "vitallens",
    faceDetectionFrequency: Double = 1.0,
    globalROI: CGRect? = nil,
    proxyURL: URL? = nil
)
```

- `method`:
    * `"vitallens"`: Auto-select best model.
    * `"vitallens-2.0"`: Force version 2.0 (HRV support).
- `faceDetectionFrequency`: How often (Hz) to run Vision face detection. Lower values save battery but track movement slower.

### Methods

- `startStream(preview: UIView?) -> AsyncStream<VitalLensResult>`: Starts the camera and yields results.
- `stopStream()`: Stops the camera and clears buffers.
- `processVideoFile(at: URL) -> VitalLensResult`: Processes a local file.

---

## `VitalLensResult`

The data structure returned by the API.

| Property | Type | Description |
| --- | --- | --- |
| `face` | `FaceData` | Bounding boxes and confidence of detected faces. |
| `heartRate` | `Vital?` | Helper to access heart rate data. |
| `ppgWaveform` | `Waveform?` | Helper to access the raw PPG signal. |
| `time` | `[Double]` | Timestamps for the data arrays. |
| `vitals` | `[String: Vital]` | Raw dictionary of all returned signals. |

### `Waveform`

Represents a signal over time.

- `data: [Float]`: The raw values.
- `confidence: [Float]`: Confidence (0-1) for each value.
- `latest: Vital?`: A helper returning the *last* value in the array (useful for UI).

```swift
// Example: Accessing the latest Heart Rate value
let currentHR = result.heartRate?.latest?.value
```