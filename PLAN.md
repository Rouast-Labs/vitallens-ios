# VitalLens iOS SDK: Architecture & Implementation Plan

**Status:** Planning / Pre-Alpha
**Goal:** Create a native Swift iOS SDK for the VitalLens API with feature parity to `vitallens.js`.
**Constraint:** "Pure API" client (no local inference models).

---

## 1. High-Level Strategy

The `vitallens-ios` SDK is a **thin, high-performance client** that offloads heavy inference to the VitalLens Cloud API but performs critical pre-processing (Face Detection, ROI Cropping, Image Stabilization) on-device to minimize bandwidth and latency.

### Core Principles

1. **Native First:** Use Apple's first-party frameworks (`Vision`, `CoreImage`, `Accelerate`, `AVFoundation`) instead of porting web dependencies (like `tfjs` or `ffmpeg.wasm`).
2. **Concurrency:** Built strictly on Swift Concurrency (`async`/`await`, `AsyncStream`, `Actors`) targeting iOS 15+.
3. **Privacy:** Face detection happens locally. Only the cropped face ROI is transmitted to the cloud.
4. **Parity:** Exact functional match with `vitallens.js` (Live Streaming, File Processing, UI Widgets).

---

## 2. Technical Stack

| Component | Web (`vitallens.js`) | iOS (`vitallens-ios`) | Reason |
| --- | --- | --- | --- |
| **Language** | TypeScript | **Swift 6** | Native performance & type safety. |
| **Face Detection** | TensorFlow.js (BlazeFace) | **Vision Framework** (`VNSequenceRequestHandler`) | Hardware-accelerated (Neural Engine), zero download size. |
| **Image Proc** | Canvas / WebGL | **Core Image** (`CIContext`) / **Accelerate** (`vImage`) | Zero-copy pixel buffer manipulation. |
| **Video Decoding** | `ffmpeg.wasm` | **AVFoundation** (`AVAssetReader`) | Hardware decoding of local video files. |
| **Math/Stats** | Custom JS / `mathjs` | **Accelerate** (`vDSP`) | Vectorized math for signal smoothing/FFTs. |
| **Networking** | `fetch` / `WebSocket` | **URLSession** (`async`/`await`) | Native networking with robust connection handling. |

---

## 3. Architecture Overview: "Everything is a Stream"

To maintain DRY (Don't Repeat Yourself) principles between Live Camera and File Analysis modes, the architecture relies on an abstraction of the video source.

### A. The Data Pipeline

1. **Source:** Emits `CMSampleBuffer` (Camera) or `CGImage` (File).
2. **Face Detection:** Vision framework analyzes the full frame to find face bounds.
3. **Normalization:** Logic converts Vision coordinates (bottom-left origin) to API-standard normalized coordinates (top-left origin).
4. **Cropping:** Core Image crops the frame to the Face ROI + Padding.
5. **Scaling:** Image is resized to the API input requirement (e.g., 72x72).
6. **Network:** Scaled frame is sent to API (HTTP POST /stream).
7. **State Management:** The API returns a `state` tensor (RNN context). The client caches this and injects it into the *next* request.
8. **Smoothing:** Raw API results are aggregated into sliding windows (smoothing heart rate, calculating HRV).
9. **Output:** Clean `VitalLensResult` yielded to the UI.

### B. Core Components (Proposed Class Structure)

#### 1. The Pipeline Core (`Sources/VitalLens/Pipeline`)

* **`FrameSource` (Protocol):** Defines an `AsyncStream<CMSampleBuffer>` interface.
* *Implementations:* `CameraSource` (wraps `AVCaptureSession`), `FileSource` (wraps `AVAssetReader`).


* **`FaceDetector` (Actor):** Wraps `VNSequenceRequestHandler`. optimized for tracking faces across temporal sequences.
* **`ImageProcessor` (Struct):** Stateless helper. Takes a buffer + ROI → returns a cropped/scaled buffer.

#### 2. The Brain (`Sources/VitalLens/Processing`)

* **`VitalLensController`:** The main facade. Coordinates the pipeline.
* **`VitalsEstimateManager`:** **(CRITICAL)** A direct port of the JS logic.
* Maintains circular buffers of raw API outputs.
* Uses `vDSP` (Accelerate) to calculate rolling averages.
* Performs client-side FFTs if raw waveforms need frequency analysis.
* *Responsibility:* Ensures the HR value doesn't "jump" erratically.



#### 3. Networking (`Sources/VitalLens/Networking`)

* **`APIClient`:** Handles the REST endpoints (`/stream`, `/file`).
* **State Injection:** Must automatically handle the `X-State` header (or multipart field) to maintain the RNN context between frames.

---

## 4. Feature Implementation Details

### Scenario A & B: Live Scanning (Custom UI)

* **Input:** `CameraSource`.
* **Logic:**
1. Start `AVCaptureSession`.
2. Feed frames to `FaceDetector`.
3. If `FaceConfidence > Threshold`, start sending cropped frames to API.
4. Receive streaming JSON.
5. Pass JSON to `VitalsEstimateManager`.
6. Publish `VitalLensResult` via `AsyncStream` or `Combine` publisher.



### Scenario C & D: Pre-built UI Widgets

* **Tech:** **SwiftUI**.
* **`VitalLensScanView`:**
* Displays camera preview (`AVCaptureVideoPreviewLayer` wrapped in `UIViewRepresentable`).
* Overlays a "Face Guide" (oval).
* Handles the 30-second countdown timer.
* Auto-stops when results are high confidence.


* **`VitalLensMonitorView`:**
* Continuous graph rendering using **Swift Charts** (iOS 16+) or simple `Path` drawing (iOS 15).
* Displays real-time PPG waveform.



### Scenario E: File Analysis

* **Input:** `FileSource` (URL).
* **Logic:**
1. Use `AVAssetReader` to pull frames as fast as possible (faster than real-time).
2. Run `FaceDetector` on specific intervals (e.g., every 0.5s) and interpolate ROI for frames in between (Optimization).
3. Batch frames into chunks (e.g., 30 frames).
4. Send `multipart/form-data` requests to `/file` endpoint.
5. Return a single aggregated `VitalLensResult`.



---

## 5. Critical Technical Challenges & Solutions

### 1. The "State" Tensor (RNN Loop)

* **Challenge:** The VitalLens API is stateless, but the model is Recurrent (RNN). The client *must* persist the "memory" of the model.
* **Solution:** The `APIClient` must parse the `state` field from every API response (Base64 encoded Float32 array), cache it in memory, and send it back in the header/body of the *next* request. If this loop breaks, accuracy drops to zero.

### 2. Coordinate Systems

* **Challenge:**
* Apple Vision: Origin is **Bottom-Left**.
* UIKit / CoreImage: Origin is **Top-Left**.
* API Expectation: Normalized Top-Left.


* **Solution:** The `FaceDetector` class must explicitly flip the Y-axis when converting Vision results to the normalized ROI used for cropping.

### 3. Client-Side Smoothing (`VitalsEstimateManager`)

* **Challenge:** The API returns raw frame-by-frame estimates which can be noisy. `vitallens.js` smooths this heavily.
* **Solution:** We must port the `smoothing` logic.
* JS: `movingAverage(data, windowSize)`
* Swift: `vDSP_meanv` (Accelerate framework) over a sliding window buffer.



---

## 6. Repository Structure

```text
Sources/
  VitalLens/
    ├── Core/
    │   ├── VitalLens.swift           // Main Configuration & Entry Point
    │   ├── VitalLensResult.swift     // Codable Data Models
    │   └── Errors.swift
    ├── Pipeline/
    │   ├── FrameSource.swift         // Protocol
    │   ├── CameraSource.swift        // AVFoundation implementation
    │   ├── FileSource.swift          // AVAssetReader implementation
    │   ├── FaceDetector.swift        // Vision Framework wrapper
    │   └── ImageProcessor.swift      // CoreImage cropping/scaling
    ├── Processing/
    │   ├── StreamProcessor.swift     // The Coordinator Actor
    │   ├── VitalsEstimateManager.swift // Smoothing & Aggregation Logic
    │   └── SignalOps.swift           // vDSP/Accelerate Math Helpers
    ├── Networking/
    │   ├── APIClient.swift           // HTTP Client
    │   └── Endpoint.swift
    └── UI/ (SwiftUI)
        ├── VitalLensScanView.swift   // 30s Scan Widget
        ├── VitalLensMonitorView.swift// Continuous Monitor Widget
        └── Components/               // Shared UI (Progress Rings, Graphs)

```

---

## 7. Next Steps (Execution Order)

1. **Foundation:** Implement `VitalLensResult` models and `APIClient` (Networking).
2. **Pipeline:** Implement `FaceDetector` (Vision) and `ImageProcessor`.
3. **Source:** Implement `CameraSource` to get live bytes.
4. **Integration:** Wire Camera -> FaceDetect -> API -> Result (The "Hello World" of streaming).
5. **Smoothing:** Port `VitalsEstimateManager` to stabilize results.
6. **UI:** Build the SwiftUI Views.
7. **Files:** Implement `FileSource` for video analysis.
