import Foundation
import AVFoundation
import VitalLensCore

#if canImport(UIKit)
import UIKit
#endif

/// The engine that coordinates the camera, face detection, and API inference loop.
actor StreamProcessor {

    #if canImport(UIKit)
    private let camera: any CameraStreaming
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
    private var isPaused: Bool = false
    
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    
    init(
        strategy: any InferenceStrategy,
        detector: any FaceDetecting = FaceDetector(),
        camera: (any CameraStreaming)? = nil
    ) {
        #if canImport(UIKit)
        self.camera = camera ?? CameraSource()
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
        
        self.config = try await strategy.resolveConfig()
        self.isPaused = false
        
        #if canImport(UIKit)
        if let wrapper = preview, let view = wrapper.view as? UIView {
            await MainActor.run { camera.showPreview(on: view) }
        }
        try await camera.start()
        #endif
        
        return AsyncStream { continuation in
            self.outputContinuation = continuation
            
            #if canImport(UIKit)
            Task {
                for await safeBuffer in camera.stream {
                    if !self.isPaused {
                        await self.processFrame(safeBuffer)
                    }
                }
            }
            #endif
        }
    }
    
    /// Pauses camera and processing without killing the stream.
    func pause() async {
        self.isPaused = true
        #if canImport(UIKit)
        camera.stop()
        #endif
    }
    
    /// Resumes camera and processing.
    func resume() async throws {
        self.isPaused = false
        #if canImport(UIKit)
        try await camera.start()
        #endif
    }
    
    func stop() {
        self.isPaused = true
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
    
    /// Processes a single frame. Exposed internally for testing.
    func processFrame(_ pixelBuffer: SendablePixelBuffer) async {
        guard let config = self.config, !isPaused else { return }
        
        let now = Date()
        let buffer = pixelBuffer.buffer
        
        if now.timeIntervalSince(lastDetectionTime) > detectionInterval {
            if let rect = try? await detector.detectFace(in: pixelBuffer) {
                self.lastFaceRect = rect
                self.lastDetectionTime = now
            }
        }
        
        let activeROIs = await bufferManager.updateAndGetActiveROIs(
            faceRect: lastFaceRect,
            config: config
        )
        
        if activeROIs.isEmpty { return }
        
        for item in activeROIs {
            if let rawBytes = try? processor.process(
                pixelBuffer: buffer,
                roi: item.roi,
                targetSize: config.inputSize
            ) {
                await bufferManager.append(bufferId: item.id, data: rawBytes)
            }
        }
        
        if !isSending {
            await checkAndSend()
        }
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
    
    func _setConfig(_ config: ModelConfig) {
        self.config = config
    }
}