# VitalLens iOS SDK: Architecture & Implementation Plan

**Status:** Alpha / Developer Preview
**Goal:** Create a native Swift iOS SDK for the VitalLens API with feature parity to `vitallens.js`.
**Constraint:** "Pure API" client (no local inference models), but **Client-Side Signal Processing** (DSP) for vitals estimation.

---

## 1. High-Level Strategy

The `vitallens-ios` SDK is a **thin, high-performance client** that offloads heavy inference to the VitalLens Cloud API but performs critical pre-processing (Face Detection, ROI Cropping) and post-processing (Vitals Estimation) on-device.

### Core Principles

1.  **Native First:** Use Apple's first-party frameworks (`Vision`, `CoreImage`, `Accelerate`, `AVFoundation`).
2.  **Concurrency:** Built strictly on Swift 6 Concurrency (`async`/`await`, `AsyncStream`, `Actors`).
3.  **Privacy:** Face detection happens locally. Only the cropped face ROI is transmitted to the cloud.
4.  **Parity:** Exact functional match with `vitallens.js` (Live Streaming, File Processing, UI Widgets).

---

## 2. Technical Stack

| Component | Web (`vitallens.js`) | iOS (`vitallens-ios`) | Status |
| :--- | :--- | :--- | :--- |
| **Language** | TypeScript | **Swift 6** | ✅ |
| **Face Detection** | TensorFlow.js | **Vision Framework** (`VNSequenceRequestHandler`) | ✅ |
| **Image Proc** | Canvas / WebGL | **Core Image** / **Accelerate** | ✅ |
| **Video Decoding** | `ffmpeg.wasm` | **AVFoundation** (`AVAssetReader`) | ⏳ Pending |
| **Math/Stats** | `mathjs` / `fft.js` | **Accelerate** (`vDSP`) | 🚧 **Missing** |
| **Networking** | `fetch` | **URLSession** | ✅ |

---

## 3. Architecture Overview: "The Hybrid Pipeline"

The architecture splits responsibility: The **Cloud** provides the raw rPPG waveform signals, and the **Client** performs the physiological estimation (FFT/Peak Detection).

### A. The Data Pipeline

1.  **Source:** Emits `CMSampleBuffer` (Camera) or `CGImage` (File). **[DONE]**
2.  **Face Detection:** Vision framework analyzes frames to find face bounds. **[DONE]**
3.  **Normalization:** Convert Vision coordinates (bottom-left) to API normalized (top-left). **[DONE]**
4.  **Cropping:** Core Image crops/scales frame to Face ROI + Padding (e.g., 40x40). **[DONE]**
5.  **Network:** Scaled frame batch is sent to API (`/stream`). **[DONE]**
6.  **State Management:** API returns `state` tensor. Client caches and injects it into next request. **[DONE]**
7.  **Waveform Stitching:** **(NEW)** Client receives short waveform chunks and stitches them into a continuous history buffer.
8.  **Estimation (DSP):** **(NEW)** Client runs FFT (for HR/RR) and Peak Detection (for HRV) on the stitched waveforms.
9.  **Output:** Clean `VitalLensResult` yielded to the UI.

### B. Core Components Structure

#### 1. The Pipeline Core (`Sources/VitalLens/Pipeline`)
* **`FrameSource` (Protocol):** Defines stream interface.
    * *Impl:* `CameraSource` (AVFoundation) ✅, `FileSource` (AVAssetReader) ⏳.
* **`FaceDetector` (Actor):** Wraps `VNSequenceRequestHandler`. ✅
* **`ImageProcessor` (Struct):** CoreImage helper. ✅

#### 2. The Brain (`Sources/VitalLens/Processing`)
* **`StreamProcessor`:** The main coordinator Actor. ✅
* **`BufferManager`:** Handles sliding windows and ROI context. ✅
* **`VitalsEstimateManager`:** **(CRITICAL MISSING)**
    * *Responsibility:* Stitches incoming waveform chunks into a circular buffer.
    * *Logic:* Calls `SignalOps` to derive scalars from waveforms.
* **`SignalOps` (Struct):** **(CRITICAL MISSING)**
    * *Tech:* `Accelerate` framework (`vDSP`).
    * *Methods:* `estimateHeartRate(waveform)`, `estimateRespiratoryRate(waveform)`, `findPeaks(ppg)`.

#### 3. Networking (`Sources/VitalLens/Networking`)
* **`APIClient`:** Handles REST endpoints and `X-State` injection. ✅

---

## 4. Feature Implementation Details

### Scenario A: Live Scanning (Custom UI)
* **Input:** `CameraSource`.
* **Logic:**
    1.  Start `AVCaptureSession`.
    2.  Feed frames to `FaceDetector`.
    3.  If `FaceConfidence > Threshold`, start sending cropped frames.
    4.  Receive raw waveforms (JSON).
    5.  **Append** waveforms to `VitalsEstimateManager`.
    6.  **Calculate** HR/RR/HRV on the updated buffer.
    7.  Publish `VitalLensResult` to `AsyncStream`.

### Scenario B: Pre-built UI Widgets
* **Tech:** **SwiftUI**.
* **`VitalLensScanView`:** ⏳
    * Displays camera preview.
    * Overlays a "Face Guide" (oval).
    * Handles 30-second countdown.
* **`VitalLensMonitorView`:** ⏳
    * Continuous graph rendering using **Swift Charts**.
    * Displays real-time PPG waveform.

### Scenario C: File Analysis
* **Input:** `FileSource` (URL). ⏳
* **Logic:**
    1.  Use `AVAssetReader` to pull frames faster than real-time.
    2.  Batch frames (e.g., 30 at a time).
    3.  Send to `/file` (or `/stream` with manual state management).
    4.  **Stitch** all resulting waveforms into one massive array.
    5.  Run global FFT/Peak Detection on the full array for maximum accuracy.

---

## 5. Critical Technical Challenges & Solutions

### 1. The "State" Tensor (RNN Loop)
* **Challenge:** The API is stateless; client must persist the "memory".
* **Solution:** `APIClient` parses `state` (Base64 Float32), caches it, and re-sends it. **[DONE]**

### 2. Client-Side DSP (Digital Signal Processing)
* **Challenge:** API returns waveforms, not values. Raw calculation is math-heavy.
* **Solution:** Use Apple's **Accelerate (vDSP)**.
    * **FFT:** Use `vDSP_fft_zrip` for Heart Rate (0.7-4Hz) and Resp Rate (0.1-1Hz).
    * **Peak Detection:** Implement a robust peak finding algorithm for HRV (SDNN/RMSSD).

### 3. Waveform Continuity
* **Challenge:** API responses come in chunks. Naive concatenation causes "clicks" or jumps at boundaries.
* **Solution:** `VitalsEstimateManager` must handle "overlap-add" or careful stitching to ensure the PPG signal remains continuous for the FFT.

---

## 6. Repository Structure

```text
Sources/
  VitalLens/
    ├── Core/
    │   ├── VitalLens.swift           // Main Entry Point ✅
    │   ├── VitalLensResult.swift     // Data Models ✅
    │   └── Errors.swift              // Error Handling ✅
    ├── Pipeline/
    │   ├── CameraSource.swift        // AVFoundation + Preview ✅
    │   ├── FileSource.swift          // AVAssetReader ⏳
    │   ├── FaceDetector.swift        // Vision Wrapper ✅
    │   └── ImageProcessor.swift      // CoreImage Ops ✅
    ├── Processing/
    │   ├── StreamProcessor.swift     // Coordinator Actor ✅
    │   ├── BufferManager.swift       // Input Frame Buffering ✅
    │   ├── VitalsEstimateManager.swift // Waveform Stitching 🚧
    │   └── SignalOps.swift           // vDSP/FFT Logic 🚧
    ├── Networking/
    │   ├── APIClient.swift           // URLSession Actor ✅
    │   └── NetworkModels.swift       // JSON Parsing ✅
    └── UI/ (SwiftUI)
        ├── VitalLensScanView.swift   // 30s Scan Widget ⏳
        ├── VitalLensMonitorView.swift// Continuous Monitor ⏳
        └── Components/               // Shared UI ⏳

```

---

## 7. Next Steps (Execution Order)

1. ~~**Foundation:** Data Models and Networking.~~ **[DONE]**
2. ~~**Pipeline:** FaceDetect, ImageProcessor, Camera.~~ **[DONE]**
3. ~~**Integration:** Wire Camera -> API -> Facade.~~ **[DONE]**
4. **Signal Processing (IMMEDIATE):**
* Create `SignalOps.swift` (vDSP FFT & Peak Detection).
* Create `VitalsEstimateManager.swift` (Waveform stitching).
* Integrate into `StreamProcessor`.


5. **UI Components:** Build `VitalLensScanView`.
6. **Files:** Implement `FileSource` and `processVideoFile`.