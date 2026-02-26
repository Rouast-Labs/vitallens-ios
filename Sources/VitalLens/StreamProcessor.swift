import Foundation
import AVFoundation
import VitalLensInference
import VitalLensCore
import CoreVideo

#if canImport(UIKit)
import UIKit
#endif

/// A transformation closure that converts a raw CVPixelBuffer into an InferenceUnit.
///
/// - Parameters:
///   - buffer: The raw camera frame.
///   - roi: The normalized Region of Interest.
///   - config: The model configuration (e.g. input size).
///   - orientation: The orientation of the image.
///   - isMirrored: Whether the image is mirrored.
/// - Returns: An InferenceUnit (either RGB data or a PixelBuffer).
public typealias FrameTransformer = @Sendable (CVPixelBuffer, CGRect, ModelConfig, CGImagePropertyOrientation, Bool) throws -> InferenceUnit

/// The core engine that coordinates the camera, ROI tracking, buffering, and the background inference loop.
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
    private var streamGeneration: Int = 0

    private var outputContinuation: AsyncStream<VitalLensResult>.Continuation?
    private var frameSignal: AsyncStream<Void>.Continuation?
    private var inferenceTask: Task<Void, Never>?

    private let debugMode: Bool

    private let defaultImageProcessor: ImageProcessor

    /// Initializes a new StreamProcessor.
    ///
    /// - Parameters:
    ///   - strategy: The inference strategy used to estimate vital signs.
    ///   - roiStrategy: The strategy used to track regions of interest (e.g., faces). Defaults to `FaceROIStrategy`.
    ///   - camera: The camera source providing the video feed. Defaults to `CameraSource`.
    ///   - transformer: An optional custom closure to preprocess frames before inference.
    ///   - waveformMode: How waveforms are accumulated by the internal session engine. Defaults to `.incremental`.
    ///   - debugMode: If true, exposes intermediate frame crops for debugging. Defaults to `false`.
    init(
        strategy: any InferenceStrategy,
        roiStrategy: (any ROIStrategy)? = nil,
        camera: (any CameraStreaming)? = nil,
        transformer: FrameTransformer? = nil,
        waveformMode: WaveformMode = .incremental,
        debugMode: Bool = false
    ) {
        #if canImport(UIKit)
        self.camera = camera ?? CameraSource()
        #endif

        self.strategy = strategy
        self.roiStrategy = roiStrategy ?? FaceROIStrategy()        
        self.bufferManager = BufferManager()
        self.waveformMode = waveformMode
        self.debugMode = debugMode
        self.defaultImageProcessor = ImageProcessor(debugMode: debugMode)
        
        if let transformer = transformer {
            self.transformer = transformer
        } else {
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
    
    /// Starts the camera stream and the background inference loop.
    ///
    /// - Parameter preview: A thread-safe wrapper containing a `UIView` to render the camera feed (iOS only).
    /// - Returns: An asynchronous stream yielding `VitalLensResult` objects.
    /// - Throws: `VitalLensError` if camera access is denied or model configuration fails.
    func start(preview: SendableUIPreview? = nil) async throws -> AsyncStream<VitalLensResult> {
        
        self.config = try await strategy.resolveConfig()
        let bufConfig = try await strategy.bufferConfig

        await bufferManager.initialize(bufferConfig: bufConfig)
        self.session = VitalLensCore.Session(config: self.config!.toSessionConfig())
        
        self.isPaused = false
        
        let (signalStream, signalContinuation) = AsyncStream.makeStream(of: Void.self)
        self.frameSignal = signalContinuation
        
        self.inferenceTask = Task {
            await self.runInferenceLoop(source: signalStream)
        }
        
        #if canImport(UIKit)
        if let wrapper = preview, let view = wrapper.view as? UIView {
            await MainActor.run { camera.showPreview(on: view) }
        }
        try await camera.start()
        #endif
        
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
    
    /// Pauses the camera stream and prevents new frames from being processed.
    func pause() async {
        self.isPaused = true
        #if canImport(UIKit)
        camera.stop()
        #endif
    }
    
    /// Resumes the camera stream and frame processing.
    ///
    /// - Throws: `VitalLensError` if the camera fails to restart.
    func resume() async throws {
        self.isPaused = false
        #if canImport(UIKit)
        try await camera.start()
        #endif
    }

    /// Resets the internal buffers and the inference session state. Use this when the subject changes abruptly.
    func reset() async {
        await bufferManager.reset()
        self.session?.reset()
        self.streamGeneration += 1
    }
    
    /// Stops the camera stream, cancels background tasks, and cleans up all resources.
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
        }
    }

    /// Sets a callback to be triggered immediately when face presence changes.
    ///
    /// - Parameter callback: A closure that receives `true` when a face enters the frame, and `false` when lost.
    func setFaceStateCallback(_ callback: (@Sendable (Bool) -> Void)?) {
        self.onFaceStateChanged = callback
    }
    
    /// Processes an incoming video frame. Handles framerate targeting, ROI determination, and buffer insertion.
    ///
    /// - Parameter frame: The input video frame and its metadata.
    func processFrame(_ frame: InputFrame) async {
        guard let config = self.config, !isPaused else { return }

        // Reset tracking if the stream loops or time travels backwards
        if frame.timestamp < lastProcessedTime { lastProcessedTime = -1.0 }

        // Throttle input to match the target FPS, allowing a 5ms jitter tolerance
        let minInterval = 1.0 / config.fpsTarget
        if frame.timestamp - lastProcessedTime < minInterval - 0.005 { 
            return 
        }
        lastProcessedTime = frame.timestamp

        let target = await roiStrategy.determineROI(
            in: frame.buffer, 
            orientation: frame.orientation, 
            isMirrored: frame.isMirrored,
            roiMethod: config.roiMethod
        )

        let isFacePresent = (target != nil)
        if isFacePresent != lastFacePresence {
            lastFacePresence = isFacePresent
            onFaceStateChanged?(isFacePresent)
        }

        // Drop accumulated temporal history immediately if the subject is lost
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
                let unit = try transformer(cvBuffer, item.roi, config, frame.orientation, frame.isMirrored)

                let context = InferenceContext(
                    timestamp: frame.timestamp,
                    orientation: frame.orientation,
                    isMirrored: frame.isMirrored,
                    roi: item.roi
                )
                
                await bufferManager.append(bufferId: item.id, unit: unit, context: context)
            } catch {
                // Silently ignore transformation errors for individual frames
            }
        }
        
        frameSignal?.yield()
    }

    nonisolated var debugImage: CGImage? {
        return defaultImageProcessor.lastProcessedCGImage
    }
    
    /// The background task that continuously polls the buffer manager and triggers the inference strategy when ready.
    ///
    /// - Parameter source: An asynchronous stream that yields void signals whenever new frames are buffered.
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
                let currentGeneration = self.streamGeneration
                
                do {
                    let (rawResult, newState) = try await strategy.infer(
                        window: window,
                        state: currentState,
                        mode: .stream,
                        model: self.config?.modelName
                    )

                    guard currentGeneration == self.streamGeneration else {
                        continue 
                    }
                    
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
