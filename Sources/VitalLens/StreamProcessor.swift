import Foundation
import AVFoundation
import VitalLensInference
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

/// The engine that coordinates the camera, and inference loop.
actor StreamProcessor {

    #if canImport(UIKit)
    private let camera: any CameraStreaming
    #endif
    
    private let roiStrategy: any ROIStrategy
    private let strategy: any InferenceStrategy
    private let transformer: FrameTransformer
    
    private let bufferManager: BufferManager
    private var session: VitalLensCore.Session?
    
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
        self.roiStrategy = roiStrategy ?? FaceROIStrategy()        
        self.bufferManager = BufferManager()
        
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
        let bufConfig = try await strategy.bufferConfig

        await bufferManager.initialize(bufferConfig: bufConfig)
        self.session = VitalLensCore.Session(config: self.config!.toSessionConfig())
        
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
            // TODO reset session?
        }
    }
    
    // MARK: - Frame Processing
    
    /// Called on every frame arrival.
    func processFrame(_ frame: InputFrame) async {
        guard let config = self.config, !isPaused else { return }

        let target = await roiStrategy.determineROI(in: frame.buffer, orientation: frame.orientation)
        await bufferManager.registerTarget(target, timestamp: frame.timestamp, config: config)
        
        let allBuffers = await bufferManager.getAllBuffers()
        if allBuffers.isEmpty { return }

        let cvBuffer = frame.buffer.buffer
        
        for item in allBuffers {
            do {
                let unit = try transformer(cvBuffer, item.roi, config)

                let context = InferenceContext(
                    timestamp: frame.timestamp,
                    orientation: frame.orientation,
                    isMirrored: frame.isMirrored,
                    roi: item.roi
                )
                
                await bufferManager.append(bufferId: item.id, unit: unit, context: context)
            } catch {
                print("[StreamProcessor] Transform failed for buffer \(item.id): \(error)")
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
        
        for await _ in source {
            if Task.isCancelled { break }
            
            while let command = await bufferManager.poll(mode: .stream) {
                if Task.isCancelled { break }
                
                if consecutiveErrors > 0 {
                    let delay = pow(2.0, Double(consecutiveErrors)) * 0.1
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                
                guard let window = await bufferManager.execute(command: command) else { break }
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
                    
                    if let sess = self.session {
                        let input = rawResult.toSessionInput()
                        let sessionResult = sess.process(input: input, mode: .incremental)
                        let refined = sessionResult.toVitalLensResult(
                            originalState: rawResult.state,
                            message: rawResult.message,
                            modelUsed: rawResult.modelUsed
                        )
                        outputContinuation?.yield(refined)
                    }
                    
                } catch {
                    consecutiveErrors += 1
                    print("[StreamProcessor] Inference Error (\(consecutiveErrors)): \(error)")
                    if consecutiveErrors >= 3 {
                        await bufferManager.reset()
                        self.session = VitalLensCore.Session(config: self.config!.toSessionConfig())
                        consecutiveErrors = 0
                    }
                }
            }
        }
    }
}
