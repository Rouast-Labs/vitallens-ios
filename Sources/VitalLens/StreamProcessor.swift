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
///   - orientation: The orientation of the image.
///   - isMirrored: Whether the image is mirrored.
/// - Returns: An InferenceUnit (either RGB data or a PixelBuffer).
public typealias FrameTransformer = @Sendable (CVPixelBuffer, CGRect, ModelConfig, CGImagePropertyOrientation, Bool) throws -> InferenceUnit

/// The engine that coordinates the camera, and inference loop.
actor StreamProcessor {

    #if canImport(UIKit)
    private let camera: any CameraStreaming
    #endif
    
    private let roiStrategy: any ROIStrategy
    private let strategy: any InferenceStrategy
    private let transformer: FrameTransformer
    private let waveformMode: WaveformMode
    
    private let bufferManager: BufferManager
    private var session: VitalLensCore.Session?
    
    private var config: ModelConfig?
    private var isPaused: Bool = false

    private var lastFacePresence: Bool = false
    private var onFaceStateChanged: (@Sendable (Bool) -> Void)?
    
    private var lastProcessedTime: TimeInterval = -1.0
        
    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    private var frameSignal: AsyncStream<Void>.Continuation?
    private var inferenceTask: Task<Void, Never>?

    // Shared ImageProcessor instance for the default transformer
    private let defaultImageProcessor = ImageProcessor()

    init(
        strategy: any InferenceStrategy,
        roiStrategy: (any ROIStrategy)? = nil,
        camera: (any CameraStreaming)? = nil,
        transformer: FrameTransformer? = nil,
        waveformMode: WaveformMode = .incremental
    ) {
        #if canImport(UIKit)
        self.camera = camera ?? CameraSource()
        #endif

        self.strategy = strategy
        self.roiStrategy = roiStrategy ?? FaceROIStrategy()        
        self.bufferManager = BufferManager()
        self.waveformMode = waveformMode
        
        // Set up the transformer
        if let transformer = transformer {
            self.transformer = transformer
        } else {
            // Default transformer for API Inference (RGB Data)
            let processor = self.defaultImageProcessor
            self.transformer = { buffer, roi, config, orientation, isMirrored in
                let data = try processor.process(
                    pixelBuffer: buffer, 
                    roi: roi, 
                    targetSize: config.inputSize,
                    orientation: orientation,
                    isMirrored: isMirrored
                )
                return .rgbData(data)
            }
        }
    }
    
    /// Starts the processing loop.
    /// - Parameter preview: A sendable wrapper containing the UIView (iOS Only).
    func start(preview: SendableUIPreview? = nil) async throws -> AsyncStream<VitalLensResult> {
        
        // Resolve config and setup session
        self.config = try await strategy.resolveConfig()
        let bufConfig = try await strategy.bufferConfig

        await bufferManager.initialize(bufferConfig: bufConfig)
        self.session = VitalLensCore.Session(config: self.config!.toSessionConfig())
        
        self.isPaused = false
        
        // Setup signal stream for incoming frames
        let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
        self.frameSignal = signalContinuation
        
        self.inferenceTask = Task {
            await self.runInferenceLoop(source: signalStream)
        }
        
        // Start camera
        #if canImport(UIKit)
        if let wrapper = preview, let view = wrapper.view as? UIView {
            await MainActor.run { camera.showPreview(on: view) }
        }
        try await camera.start()
        #endif
        
        // Return output stream
        let (outputStream, outputContinuation) = AsyncStream.makeStream(of: VitalLensResult.self)
        self.outputContinuation = outputContinuation
        
        #if canImport(UIKit)
        Task {
            for await frame in camera.stream {
                if !self.isPaused {
                    await self.processFrame(frame)
                }
            }
        }
        #endif
        
        return outputStream
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
            // TODO do we need to reset session?
        }
    }

    func setFaceStateCallback(_ callback: (@Sendable (Bool) -> Void)?) {
        self.onFaceStateChanged = callback
    }
    
    /// Called on every frame arrival.
    func processFrame(_ frame: InputFrame) async {
        guard let config = self.config, !isPaused else { return }

        // Enforce the target FPS by dropping excess frames
        if frame.timestamp < lastProcessedTime { lastProcessedTime = -1.0 }

        let minInterval = 1.0 / config.fpsTarget
        if frame.timestamp - lastProcessedTime < minInterval - 0.005 { 
            return 
        }
        lastProcessedTime = frame.timestamp

        let target = await roiStrategy.determineROI(in: frame.buffer, orientation: frame.orientation)
        
        // Notify the UI instantly if the face state changes
        let isFacePresent = (target != nil)
        if isFacePresent != lastFacePresence {
            lastFacePresence = isFacePresent
            onFaceStateChanged?(isFacePresent)
        }

        // If the face is lost, purge buffers to stop API calls and clear memory
        guard target != nil else {
            await bufferManager.reset()
            return
        }
        
        await bufferManager.registerTarget(target, timestamp: frame.timestamp, config: config)
        
        let allBuffers = await bufferManager.getAllBuffers()
        if allBuffers.isEmpty { return }

        let cvBuffer = frame.buffer.buffer
        
        for item in allBuffers {
            do {
                // Transform frame using the updated closure signature
                let unit = try transformer(cvBuffer, item.roi, config, frame.orientation, frame.isMirrored)

                let context = InferenceContext(
                    timestamp: frame.timestamp,
                    orientation: frame.orientation,
                    isMirrored: frame.isMirrored,
                    roi: item.roi
                )
                
                await bufferManager.append(bufferId: item.id, unit: unit, context: context)
            } catch {
                // print("[StreamProcessor] Transform failed for buffer \(item.id): \(error)")
            }
        }
        
        // Signal inference loop
        frameSignal?.yield()
    }
    
    /// Background task that monitors buffers and triggers inference when ready.
    private func runInferenceLoop(source: AsyncStream<Void>) async {
        
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
                        model: self.config?.modelName
                    )
                    
                    consecutiveErrors = 0
                    
                    await bufferManager.updateState(newState)
                    
                    if let sess = self.session {
                        let input = rawResult.toSessionInput()
                        let sessionResult = sess.process(input: input, mode: self.waveformMode)
                        let refined = sessionResult.toVitalLensResult(
                            originalState: rawResult.state,
                            message: rawResult.message,
                            modelUsed: rawResult.modelUsed
                        )
                        outputContinuation?.yield(refined)
                    }
                    
                } catch {
                    consecutiveErrors += 1
                    
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