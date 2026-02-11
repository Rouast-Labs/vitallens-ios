import Foundation
import AVFoundation
import VitalLensCore
import CoreVideo

#if canImport(UIKit)
import UIKit
#endif

/// A transformation closure that converts a raw CVPixelBuffer into an InferenceUnit.
/// - Parameters:
///   - buffer: The raw camera frame.
///   - roi: The normalized Region of Interest.
///   - config: The model configuration (e.g. input size).
/// - Returns: An InferenceUnit (either RGB data or a PixelBuffer).
public typealias FrameTransformer = @Sendable (CVPixelBuffer, CGRect, ModelConfig) throws -> InferenceUnit

/// The engine that coordinates the camera, face detection, and API inference loop.
actor StreamProcessor {

    #if canImport(UIKit)
    private let camera: any CameraStreaming
    #endif
    
    private let detector: any FaceDetecting
    private let strategy: any InferenceStrategy
    private let transformer: FrameTransformer
    
    private let bufferManager: BufferManager
    private let vitalsEstimator: VitalsEstimateManager
    
    private var config: ModelConfig?
    private var isPaused: Bool = false
        
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    private var frameSignal: AsyncStream<Void>.Continuation?
    private var inferenceTask: Task<Void, Never>?

    // Default Processor (Retained if no custom transformer is provided)
    private let defaultImageProcessor = ImageProcessor()

    init(
        strategy: any InferenceStrategy,
        roiStrategy: (any ROIStrategy)? = nil,
        camera: (any CameraStreaming)? = nil,
        transformer: FrameTransformer? = nil
    ) {
        #if canImport(UIKit)
        self.camera = camera ?? CameraSource()
        #endif

        self.strategy = strategy
        // Default to Face Detection if no strategy provided
        self.roiStrategy = roiStrategy ?? FaceROIStrategy()
        
        self.bufferManager = BufferManager()
        self.vitalsEstimator = VitalsEstimateManager()
        
        // Default Transformer: Convert to RGB Data using ImageProcessor
        if let transformer = transformer {
            self.transformer = transformer
        } else {
            // Capture the processor instance for the closure
            let processor = self.defaultImageProcessor
            self.transformer = { buffer, roi, config in
                let data = try processor.process(
                    pixelBuffer: buffer, 
                    roi: roi, 
                    targetSize: config.inputSize
                )
                return .rgbData(data)
            }
        }
    }
    
    /// Starts the processing loop.
    /// - Parameter preview: A sendable wrapper containing the UIView (iOS Only).
    func start(preview: SendableUIPreview? = nil) async throws -> AsyncStream<VitalLensResult> {
        
        // 1. Prepare Config
        self.config = try await strategy.resolveConfig()
        self.isPaused = false
        
        // 2. Setup Signaling for Inference Loop
        let signalStream = AsyncStream<Void> { continuation in
            self.frameSignal = continuation
        }
        
        self.inferenceTask = Task {
            await self.runInferenceLoop(source: signalStream)
        }
        
        // 3. Start Camera (Main Actor)
        #if canImport(UIKit)
        if let wrapper = preview, let view = wrapper.view as? UIView {
            await MainActor.run { camera.showPreview(on: view) }
        }
        try await camera.start()
        #endif
        
        // 4. Return Output Stream
        return AsyncStream { continuation in
            self.outputContinuation = continuation
            
            #if canImport(UIKit)
            Task {
                for await frame in camera.stream {
                    if !self.isPaused {
                        await self.processFrame(frame)
                    }
                }
            }
            #endif
        }
    }
    
    func pause() async {
        self.isPaused = true
        #if canImport(UIKit)
        camera.stop()
        #endif
    }
    
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
    
    // MARK: - Frame Processing
    
    /// Called on every frame arrival.
    func processFrame(_ frame: InputFrame) async {
        guard let config = self.config, !isPaused else { return }
        
        let pixelBuffer = frame.buffer
        let orientation = frame.orientation
        let isMirrored = frame.isMirrored
        let timestamp = frame.timestamp
        
        // Ask Strategy for ROIs using the correct orientation
        let targets = await roiStrategy.determineROIs(in: pixelBuffer, orientation: orientation)
        
        // Sync with Buffer Manager (Handles Overlap/Drift)
        let activeROIs = await bufferManager.updateAndGetActiveROIs(
            targets: targets,
            constraints: strategy.batchConstraints,
            config: config
        )
        
        if activeROIs.isEmpty { return }
        
        let buffer = pixelBuffer.buffer
        
        // Transform & Append
        for item in activeROIs {
            do {
                let unit = try transformer(buffer, item.roi, config)

                let context = InferenceContext(
                    timestamp: timestamp,
                    orientation: orientation,
                    isMirrored: isMirrored,
                    roi: item.roi
                )
                
                await bufferManager.append(bufferId: item.id, unit: unit, context: context)
            } catch {
                print("[StreamProcessor] Transform failed: \(error)")
            }
        }
        
        // Wake up inference loop
        frameSignal?.yield()
    }
    
    // MARK: - Inference Loop
    
    /// Background task that monitors buffers and triggers inference when ready.
    private func runInferenceLoop(source: AsyncStream<Void>) async {
        print("[StreamProcessor] Inference Loop Started")
        
        var consecutiveErrors = 0
        let maxRetries = 3
        
        for await _ in source {
            if Task.isCancelled { break }
            
            // Check if any buffer is ready for the current mode (.stream)
            while let buffer = await bufferManager.getReadyBuffer(mode: .stream) {
                if Task.isCancelled { break }
                
                // Backoff logic
                if consecutiveErrors > 0 {
                    let delay = pow(2.0, Double(consecutiveErrors)) * 0.1
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                
                // Consume returns generic units
                guard let window = await buffer.consume() else { break }
                let currentState = await bufferManager.getState()
                
                do {
                    let (rawResult, newState) = try await strategy.infer(
                        window: window,
                        state: currentState,
                        mode: .stream,
                        model: nil
                    )
                    
                    consecutiveErrors = 0
                    
                    await bufferManager.updateState(newState)
                    
                    // Estimate Vitals
                    if let config = self.config {
                        let refined = await vitalsEstimator.process(chunk: rawResult, config: config)
                        outputContinuation?.yield(refined)
                    }
                    
                } catch {
                    consecutiveErrors += 1
                    print("[StreamProcessor] Inference Error (\(consecutiveErrors)): \(error)")
                    
                    if consecutiveErrors >= maxRetries {
                        print("[StreamProcessor] Max retries hit. Resetting State.")
                        await bufferManager.reset()
                        await vitalsEstimator.reset()
                        consecutiveErrors = 0
                    }
                }
            }
        }
    }
    
    func _setConfig(_ config: ModelConfig) {
        self.config = config
    }
}