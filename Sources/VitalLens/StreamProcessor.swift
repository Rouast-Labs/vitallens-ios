import Foundation
import AVFoundation
import VitalLensCore

#if canImport(UIKit)
import UIKit
#endif

actor StreamProcessor {

    #if canImport(UIKit)
    private let camera: CameraSource
    #endif
    
    private let detector: FaceDetector
    private let processor: ImageProcessor
    
    private let strategy: any InferenceStrategy
    
    private let bufferManager: BufferManager
    private let vitalsEstimator: VitalsEstimateManager
    
    private var config: ModelConfig?
    private let detectionInterval: TimeInterval = 1
    
    private var lastFaceRect: CGRect?
    private var lastDetectionTime: Date = .distantPast
    private var isSending: Bool = false
    
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    
    init(strategy: any InferenceStrategy) {
        #if canImport(UIKit)
        self.camera = CameraSource()
        #endif

        self.detector = FaceDetector()
        self.processor = ImageProcessor()
        self.strategy = strategy
        self.bufferManager = BufferManager()
        self.vitalsEstimator = VitalsEstimateManager()
    }
    
    #if canImport(UIKit)
    func start(preview: UIView?) async throws -> AsyncStream<VitalLensResult> {
        
        // 1. Resolve Configuration (Network or Local)
        self.config = try await strategy.resolveConfig()
        
        if let view = preview {
            await MainActor.run {
                camera.showPreview(on: view)
            }
        }
        
        try await camera.start()
        
        return AsyncStream { continuation in
            self.outputContinuation = continuation
            Task { await self.processStream() }
        }
    }

    private func processStream() async {
        guard let config = self.config else { return }
        
        for await buffer in camera.stream {
            let now = Date()
            
            // Face Detection (Local)
            if now.timeIntervalSince(lastDetectionTime) > detectionInterval {
                if let rect = try? await detector.detectFace(in: buffer) {
                    self.lastFaceRect = rect
                    self.lastDetectionTime = now
                }
            }
            
            let activeROIs = await bufferManager.updateAndGetActiveROIs(
                faceRect: lastFaceRect,
                config: config
            )
            
            if activeROIs.isEmpty { continue }
            
            // Image Processing (Crop/Resize)
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
    }
    #else
    func start() async throws -> AsyncStream<VitalLensResult> {
        throw VitalLensError.processingError("Not supported on macOS")
    }
    #endif

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
        
        guard let buffer = await bufferManager.getReadyBuffer() else {
            return
        }
        
        guard let payload = await buffer.consume() else { return }
        
        self.isSending = true
        
        let state = await bufferManager.getState()
        
        do {
            let rawResult = try await strategy.process(
                frames: payload,
                state: state,
                meta: [:]
            )
            
            // Handle RNN State
            if let stateData = rawResult.state?.data,
               let decodedData = Data(base64Encoded: stateData) {
                let newState = decodedData.withUnsafeBytes {
                    Array($0.bindMemory(to: Float.self))
                }
                await bufferManager.updateState(newState)
            }
            
            // Process Vitals Locally (HRV, Smoothing, Derivation)
            let refinedResult = await vitalsEstimator.process(chunk: rawResult, config: config)
            
            outputContinuation?.yield(refinedResult)
            
        } catch {
            print("VitalLens Stream Error: \(error)")
        }
        
        self.isSending = false
        
        // Recursive check for buffered frames
        await checkAndSend()
    }
}