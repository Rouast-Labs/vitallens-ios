# Examples

These examples demonstrate the different ways to integrate the VitalLens SDK into your iOS application, ranging from drop-in UI components to fully custom data pipelines.

## SwiftUI Pre-built View (Easiest)

The fastest way to get started is by using the `VitalLensScanView` from the `VitalLensUI` module. It handles camera permissions, user guidance, and the measurement timer automatically.

```swift
import SwiftUI
import VitalLensUI

struct SimpleScanExample: View {
    var body: some View {
        VitalLensScanView(
            apiKey: "YOUR_API_KEY",
            method: "vitallens",
            mode: .eco // 15 FPS
        ) { result in
            if let hr = result.heartRate?.value {
                print("✅ Scan Complete! Heart Rate: \(hr) bpm")
            }
            if let hrv = result.hrvSdnn?.value {
                print("📈 HRV (SDNN): \(hrv) ms")
            }
        }
    }
}
```

## Custom Camera Stream

If you want to build a completely custom UI but still let the SDK manage the camera hardware, use the `VitalLens` client directly. Pass a `UIView` to `startStream` to render the camera feed.

```swift
import UIKit
import VitalLens

class CustomCameraViewController: UIViewController {
    private let client = VitalLens(apiKey: "YOUR_API_KEY")
    private var previewView: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Setup a view to hold the camera preview
        previewView = UIView(frame: view.bounds)
        view.addSubview(previewView)
        
        // Listen for face detection events to update custom UI instructions
        client.onFaceStateChanged = { isPresent in
            print(isPresent ? "Face found, analyzing..." : "Please face the camera.")
        }
        
        Task {
            await startVitalsStream()
        }
    }
    
    private func startVitalsStream() async {
        do {
            let stream = try await client.startStream(preview: previewView)
            
            // Consume the continuous stream of results
            for await result in stream {
                if let hr = result.heartRate?.value {
                    print("Live HR: \(hr) bpm")
                }
            }
        } catch {
            print("Stream error: \(error)")
        }
    }
    
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        client.stopStream()
    }
}
```

## Analyzing Video Files

You can process pre-recorded video files (e.g., loaded from the Photo Library or bundled with your app). The SDK handles chunking, frame extraction, and API communication automatically.

```swift
import Foundation
import VitalLens

func analyzeLocalVideo() async {
    let client = VitalLens(apiKey: "YOUR_API_KEY", method: "vitallens-2.0")
    
    guard let videoURL = Bundle.main.url(forResource: "sample_video_1", withExtension: "mp4") else {
        print("Video not found")
        return
    }
    
    do {
        print("Processing video file...")
        let result = try await client.processVideoFile(at: videoURL)
        
        print("--- Final Results ---")
        print("Avg Heart Rate:   \(result.heartRate?.value ?? 0) bpm")
        print("Respiratory Rate: \(result.respiratoryRate?.value ?? 0) rpm")
        print("HRV (SDNN):       \(result.hrvSdnn?.value ?? 0) ms")
        
    } catch {
        print("Analysis failed: \(error)")
    }
}
```

## Bring Your Own Camera (`PassiveSource`)

If your app already controls the `AVCaptureSession` (for instance, you are using WebRTC, ARKit, or custom recording), use `PassiveSource` to inject `CVPixelBuffer` frames directly into the SDK.

```swift
import AVFoundation
import VitalLens
import VitalLensInference

class MyExistingCameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    
    private let passiveSource = PassiveSource()
    private var client: VitalLens!
    
    override init() {
        super.init()
        
        // Initialize client with the passive source
        client = VitalLens(apiKey: "YOUR_API_KEY", source: passiveSource)
        
        Task {
            // Start the stream. No camera hardware will be claimed.
            let stream = try await client.startStream()
            for await result in stream {
                print("Injected HR: \(result.heartRate?.value ?? 0)")
            }
        }
    }

    // Your existing camera delegate method
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        
        // Inject the frame into VitalLens
        passiveSource.inject(
            buffer: pixelBuffer,
            orientation: .up, 
            isMirrored: true, 
            timestamp: timestamp
        )
    }
}
```