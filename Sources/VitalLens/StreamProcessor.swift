import Foundation
import AVFoundation
import VitalLensCore

#if canImport(UIKit)
import UIKit
#endif

/// The engine that coordinates the camera, face detection, and API inference loop.
actor StreamProcessor {

    #if canImport(UIKit)
    private let camera: CameraSource
    #endif
    
    private let detector: any FaceDetecting
    private let processor: ImageProcessor
    
    private let strategy: any InferenceStrategy
    
    private let bufferManager: BufferManager
    private let vitalsEstimator: VitalsEstimateManager
    
    // State
    private var config: ModelConfig?
    private var detectionInterval: TimeInterval = 0.5
    
    private var lastFaceRect: CGRect?
    private var lastDetectionTime: Date = .distantPast
    private var isSending: Bool = false
    
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    
    init(strategy: any InferenceStrategy, detector: any FaceDetecting = FaceDetector()) {
        #if canImport(UIKit)
        self.camera = CameraSource()
        #endif

        self.detector = detector
        self.processor = ImageProcessor()
        self.strategy = strategy
        self.bufferManager = BufferManager()
        self.vitalsEstimator = VitalsEstimateManager()
    }
    
    /// Starts the processing loop.
    /// - Parameter preview: A sendable wrapper containing the UIView (iOS Only).
    func start(preview: SendableUIPreview? = nil) async throws -> AsyncStream<VitalLensResult> {
        // 1. Resolve Config
        self.config = try await strategy.resolveConfig()
        
        // 2. Setup Camera (iOS Only)
        #if canImport(UIKit)
        if let wrapper = preview, let view = wrapper.view as? UIView {
            // Safe: We jump back to MainActor to touch the UIView
            await MainActor.run { camera.showPreview(on: view) }
        }
        try await camera.start()
        #endif
        
        // 3. Return Stream
        return AsyncStream { continuation in
            self.outputContinuation = continuation
            
            #if canImport(UIKit)
            Task {
                for await sampleBuffer in camera.stream {
                    guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }
                    let safeBuffer = SendablePixelBuffer(pixelBuffer)
                    await self.processFrame(safeBuffer)
                }
            }
            #endif
        }
    }
    
    /// Processes a single frame. Exposed internally for testing.
    func processFrame(_ pixelBuffer: SendablePixelBuffer) async {
        guard let config = self.config else { return }
        let now = Date()
        
        let buffer = pixelBuffer.buffer
        
        // 1. Run Face Detection
        if now.timeIntervalSince(lastDetectionTime) > detectionInterval {
            if let rect = try? await detector.detectFace(in: pixelBuffer) {
                self.lastFaceRect = rect
                self.lastDetectionTime = now
            }
        }
        
        // 2. Determine Active ROIs
        let activeROIs = await bufferManager.updateAndGetActiveROIs(
            faceRect: lastFaceRect,
            config: config
        )
        
        if activeROIs.isEmpty { return }
        
        // 3. Crop & Scale
        for item in activeROIs {
            if let rawBytes = try? processor.process(
                pixelBuffer: buffer,
                roi: item.roi,
                targetSize: config.inputSize
            ) {
                await bufferManager.append(bufferId: item.id, data: rawBytes)
            }
        }
        
        // 4. Check Batch
        if !isSending {
            await checkAndSend()
        }
    }
    
    func _setConfig(_ config: ModelConfig) {
        self.config = config
    }

    func stop() {
        #if canImport(UIKit)
        camera.stop()
        #endif
        
        outputContinuation?.finish()
        outputContinuation = nil
        
        Task {
            await bufferManager.reset()
            await vitalsEstimator.reset() 
        }
        isSending = false
    }
    
    private func checkAndSend() async {
        guard let config = self.config else { return }
        
        guard let buffer = await bufferManager.getReadyBuffer() else { return }
        guard let payload = await buffer.consume() else { return }
        
        self.isSending = true
        
        let state = await bufferManager.getState()
        
        do {
            let rawResult = try await strategy.process(
                frames: payload,
                state: state,
                meta: [:]
            )
            
            if let stateData = rawResult.state?.data,
               let decodedData = Data(base64Encoded: stateData) {
                let newState = decodedData.withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                await bufferManager.updateState(newState)
            }
            
            let refinedResult = await vitalsEstimator.process(chunk: rawResult, config: config)
            outputContinuation?.yield(refinedResult)
            
        } catch {
            print("[StreamProcessor] Error: \(error)")
        }
        
        self.isSending = false
        await checkAndSend()
    }
}