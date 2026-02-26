# Advanced Usage & Customization

The `vitallens-ios` SDK is designed to be highly modular. While the pre-built SwiftUI views and standard `VitalLens` client handle most use cases, you can bypass them to integrate deeply into existing architectures or run custom local models.

## Custom Camera Injection (`PassiveSource`)

If your app already manages its own `AVCaptureSession` (e.g., for WebRTC, ARKit, or custom recording), you cannot use the default `CameraSource`. Instead, use `PassiveSource` to inject frames directly into the SDK's processing pipeline.

```swift
import VitalLens
import VitalLensInference

// 1. Initialize a PassiveSource
let passiveSource = PassiveSource()

// 2. Pass it to the VitalLens client
let client = VitalLens(
    source: passiveSource,
    strategy: APIInference(apiKey: "YOUR_KEY")
)

// 3. Start the inference stream
Task {
    let stream = try await client.startStream()
    for await result in stream {
        print("HR: \(result.heartRate?.value ?? 0)")
    }
}

// 4. Inject frames from your own AVCaptureVideoDataOutput
func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
    
    let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
    
    passiveSource.inject(
        buffer: pixelBuffer,
        orientation: .up, // Adjust based on your device orientation
        isMirrored: true, // Typically true for front-facing cameras
        timestamp: timestamp
    )
}
```

## Local Inference (Custom CoreML)

The `StreamProcessor` is entirely decoupled from the API. It relies on the `InferenceStrategy` protocol. If you are an Enterprise customer with a custom CoreML model, you can run inference completely on-device without hitting the network.

To do this, subclass `LocalInferenceBase`:

```swift
import VitalLens
import VitalLensInference
import CoreVideo

class MyCoreMLStrategy: LocalInferenceBase {
    
    // Initialize with your model's required configuration
    init() {
        let config = ModelConfig(
            nInputs: 8,
            inputSize: 72,
            fpsTarget: 30.0,
            roiMethod: "face",
            supportedVitals: ["heart_rate", "respiratory_rate"]
        )
        super.init(config: config)
    }

    override func predict(frames: [CVPixelBuffer], state: (any InferenceState)?) async throws -> (VitalLensResult, (any InferenceState)?) {
        
        // 1. Convert CVPixelBuffers to your CoreML MLMultiArray format
        // 2. Run your CoreML prediction
        // 3. Package the raw model output (waveforms) into a VitalLensResult.
        // Note: Do not calculate vitals like 'heart_rate' here. The SDK's 
        // internal engine will derive them automatically from the raw signal.
        
        let mockPPG: [Float] = Array(repeating: 0.5, count: frames.count)
        let mockConf: [Float] = Array(repeating: 0.9, count: frames.count)
        
        let result = VitalLensResult(
            face: FaceData(coordinates: nil, confidence: nil, note: nil),
            vitals: [:], // Leave empty; SDK will compute the scalar values
            waveforms: [
                "ppg_waveform": Waveform(data: mockPPG, confidence: mockConf, unit: "unitless", note: nil)
            ],
            time: frames.map { _ in Date().timeIntervalSince1970 }
        )
        
        // Return the result and the updated RNN state (if applicable)
        return (result, state)
    }
}

// Use it in the client
let localClient = VitalLens(
    source: CameraSource(),
    strategy: MyCoreMLStrategy()
)
```

## High-Performance Image Processing

Under the hood, the SDK uses the Accelerate framework (`vImage`) via the `ImageProcessor` class. It performs highly optimized, hardware-accelerated cropping, scaling, rotation, reflection, and colorspace conversion (YpCbCr to ARGB/RGB).

If you are writing a custom `FrameTransformer` or building your own pipeline, you can access this processor directly:

```swift
let processor = ImageProcessor()

let rgbData = try processor.process(
    pixelBuffer: rawCameraBuffer,
    roi: faceRect,
    targetSize: 40,
    orientation: .up,
    isMirrored: false
)
```

For CoreML integrations, you can output directly to a `CVPixelBuffer` instead of raw bytes:

```swift
let croppedBuffer = try processor.processToPixelBuffer(...)
```
