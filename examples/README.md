# Usage Examples

If the pre-built UI components don't fit your needs, you can use the `VitalLens` client directly to manage the data stream.

## 1. Custom Camera Loop

Use this pattern if you want to build your own UI overlays or integrate rPPG into an existing camera view.

```swift
import UIKit
import VitalLens

class CameraViewController: UIViewController {
    private let client = VitalLens(apiKey: "YOUR_KEY", method: .vitalLens2)
    private var previewView: UIView!

    override func viewDidLoad() {
        super.viewDidLoad()
        setupPreview()
        
        Task {
            await startVitals()
        }
    }
    
    func startVitals() async {
        do {
            // client.startStream handles the camera and yields results
            let stream = try await client.startStream(preview: previewView)
            
            for await result in stream {
                // Update your custom UI here
                if let hr = result.heartRate?.latest?.value {
                    print("Live HR: \(hr)")
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

## 2. Analyzing Video Files

You can process pre-recorded videos (e.g., from the Photo Library). This mimics the behavior of the API's `/file` endpoint but handles chunking/uploading automatically.

```swift
import VitalLens

func analyzeLocalVideo(url: URL) async {
    let client = VitalLens(apiKey: "YOUR_KEY", method: .vitalLens2)
    
    do {
        print("Uploading and analyzing...")
        let result = try await client.processVideoFile(at: url)
        
        print("--- Final Results ---")
        print("Avg HR: \(result.heartRate?.latest?.value ?? 0)")
        print("SDNN:   \(result.hrvSdnn?.latest?.value ?? 0)")
        
    } catch {
        print("Analysis failed: \(error)")
    }
}
```