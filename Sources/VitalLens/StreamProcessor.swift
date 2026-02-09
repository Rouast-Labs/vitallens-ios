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
    
    private var config: ModelConfig?
    private var detectionInterval: TimeInterval = 0.5
    
    private var lastFaceRect: CGRect?
    private var lastDetectionTime: Date = .distantPast
    private var isPaused: Bool = false
    
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    
    // MARK: - Concurrency Control
    /// A signaling mechanism to wake up the inference loop when new frames arrive.
    private var frameSignal: AsyncStream<Void>.Continuation?
    /// The long-running task that handles API communication.
    private var inferenceTask: Task<Void, Never>?
    
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
        
        // 1. Resolve Config (Blocking Init)
        self.config = try await strategy.resolveConfig()
        self.isPaused = false
        
        // 2. Setup Signaling for the Inference Loop
        let signalStream = AsyncStream<Void> { continuation in
            self.frameSignal = continuation
        }
        
        // 3. Spawn the Inference Loop (Detached)
        // This runs independently of the camera and will not block ingestion.
        self.inferenceTask = Task {
            await self.runInferenceLoop(source: signalStream)
        }
        
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
        
        // Kill the background inference loop
        inferenceTask?.cancel()
        frameSignal?.finish()
        inferenceTask = nil
        frameSignal = nil
        
        outputContinuation?.finish()
        outputContinuation = nil
        
        Task {
            await bufferManager.reset()
            await vitalsEstimator.reset()
        }
    }
    
    // MARK: - Process 1: Ingestion Loop (High Frequency)
    
    /// Processes a single frame. Driven by the camera (e.g., 30 FPS).
    /// This method must remain fast and non-blocking.
    func processFrame(_ pixelBuffer: SendablePixelBuffer) async {
        guard let config = self.config, !isPaused else { return }
        
        // A. Face Detection (Fire-and-Forget)
        let now = Date()
        if now.timeIntervalSince(lastDetectionTime) > detectionInterval {
            Task {
                if let rect = try? await detector.detectFace(in: pixelBuffer) {
                    await self.updateFaceRect(rect)
                }
            }
            self.lastDetectionTime = now
        }
        
        // B. Process & Accumulate (Synchronous & Fast)
        let activeROIs = await bufferManager.updateAndGetActiveROIs(
            faceRect: lastFaceRect,
            config: config
        )
        
        if activeROIs.isEmpty { return }
        
        let buffer = pixelBuffer.buffer
        for item in activeROIs {
            // High-performance vDSP cropping/scaling (< 2ms)
            if let rawBytes = try? processor.process(
                pixelBuffer: buffer,
                roi: item.roi,
                targetSize: config.inputSize
            ) {
                await bufferManager.append(bufferId: item.id, data: rawBytes)
            }
        }
        
        // C. Signal Inference Loop
        frameSignal?.yield()
    }
    
    private func updateFaceRect(_ rect: CGRect) {
        self.lastFaceRect = rect
    }
    
    // MARK: - Process 2: Inference Loop (Variable Frequency)
    
    /// The background loop that manages API communication.
    /// It drains the buffer (handling dynamic batch sizes) and maintains state continuity.
    private func runInferenceLoop(source: AsyncStream<Void>) async {
        print("[StreamProcessor] Inference Loop Started")
        
        for await _ in source {
            if Task.isCancelled { break }
            
            // Keep draining the buffer as long as we have enough data to form a batch.
            // This loop naturally handles "catch up" if the API was slow.
            while let buffer = await bufferManager.getReadyBuffer() {
                if Task.isCancelled { break }
                
                // 1. Dynamic Batching
                // consume() grabs ALL available frames in the buffer.
                guard let payload = await buffer.consume() else { break }
                let state = await bufferManager.getState()
                
                do {
                    // 2. Blocking Inference
                    // This waits for the Network/CoreML result.
                    // Meanwhile, processFrame is still running and filling the buffer!
                    let rawResult = try await strategy.process(
                        frames: payload,
                        state: state,
                        meta: [:]
                    )
                    
                    // 3. State Update
                    // Must happen immediately to ensure continuity for the NEXT batch.
                    if let stateData = rawResult.state?.data,
                       let decoded = Data(base64Encoded: stateData) {
                        let newState = decoded.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                        await bufferManager.updateState(newState)
                    }
                    
                    // 4. Emit Result
                    if let config = self.config {
                        let refined = await vitalsEstimator.process(chunk: rawResult, config: config)
                        outputContinuation?.yield(refined)
                    }
                    
                } catch {
                    print("[StreamProcessor] Inference Error: \(error)")
                    // In a real app, you might want to backoff or reset state here.
                }
            }
        }
        
        print("[StreamProcessor] Inference Loop Ended")
    }
    
    func _setConfig(_ config: ModelConfig) {
        self.config = config
    }
}