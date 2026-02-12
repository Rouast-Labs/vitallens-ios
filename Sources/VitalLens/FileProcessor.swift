import Foundation
import VitalLensCore
import CoreVideo

/// Handles the two-pass processing of video files for high-accuracy vital sign estimation.
///
/// - Pass 1 (Scanning): Iterates through the video to detect faces and calculate a stable, global ROI.
/// - Pass 2 (Inference): Processes frames using the stable ROI and batches them for the inference strategy.
actor FileProcessor {
    
    private let url: URL
    private let processor: ImageProcessor
    private let detector: any FaceDetecting
    private let vitalsEstimator: VitalsEstimateManager
    
    init(url: URL, detector: any FaceDetecting = FaceDetector()) {
        self.url = url
        self.detector = detector
        self.processor = ImageProcessor()
        self.vitalsEstimator = VitalsEstimateManager()
    }
    
    /// Execute the full processing pipeline.
    func process(strategy: any InferenceStrategy, globalROI: CGRect? = nil) async throws -> VitalLensResult {
        // 1. Resolve Config & Constraints
        let config = try await strategy.resolveConfig()
        let constraints = strategy.batchConstraints
        
        // 2. Establish ROI (Pass 1)
        let finalROI: CGRect
        if let provided = globalROI {
            finalROI = provided
        } else {
            print("[FileProcessor] Starting Pass 1: ROI Scanning...")
            finalROI = try await performScanningPass(config: config)
            print("[FileProcessor] Pass 1 Complete. ROI: \(finalROI)")
        }
        
        // 3. Inference (Pass 2)
        print("[FileProcessor] Starting Pass 2: Inference...")
        return try await performInferencePass(
            roi: finalROI,
            config: config,
            constraints: constraints,
            strategy: strategy
        )
    }
    
    // MARK: - Pass 1: Scanning
    
    /// Scans the video to determine a stable "Median Face" and derives the ROI.
    private func performScanningPass(config: ModelConfig) async throws -> CGRect {
        let source = try await FileSource.from(url: url)
        
        // We optimize by checking only a subset of frames (e.g. 2 Hz stride)
        // This is significantly faster than running face detection on every frame.
        let stride = max(1, Int(source.nominalFrameRate * 0.5))
        var frameCount = 0
        var detections: [CGRect] = []
        
        for await frame in source.frames() {
            frameCount += 1
            if frameCount % stride != 0 { continue }
            
            // Note: FileSource determines orientation from track transform
            if let rect = try? await detector.detectFace(in: frame, orientation: source.orientation) {
                detections.append(rect)
            }
        }
        
        guard !detections.isEmpty else {
            throw VitalLensError.processingError("No face detected in video file.")
        }
        
        // Calculate the "Median Face" to avoid outliers (jitters/false positives).
        // 1. Calculate Centroid of all detections
        let totalX = detections.reduce(0) { $0 + $1.midX }
        let totalY = detections.reduce(0) { $0 + $1.midY }
        let centroid = CGPoint(x: totalX / CGFloat(detections.count), y: totalY / CGFloat(detections.count))
        
        // 2. Find the single detection closest to the centroid
        let bestFace = detections.min { a, b in
            let distA = hypot(a.midX - centroid.x, a.midY - centroid.y)
            let distB = hypot(b.midX - centroid.x, b.midY - centroid.y)
            return distA < distB
        } ?? detections[0]
        
        return ROICalculator.calculateROI(from: bestFace, method: config.roiMethod)
    }
    
    // MARK: - Pass 2: Inference
    
    /// Reads the video linearly, applies the fixed ROI, and performs batched inference.
    private func performInferencePass(
        roi: CGRect,
        config: ModelConfig,
        constraints: BatchConstraints,
        strategy: any InferenceStrategy
    ) async throws -> VitalLensResult {
        
        // Reset source to read from start
        let source = try await FileSource.from(url: url)
        let nominalFPS = Double(source.nominalFrameRate)
        
        // Use a local FrameBuffer instance.
        // We don't need BufferManager here because we aren't handling drift/multiple faces.
        let buffer = FrameBuffer(roi: roi, config: config, constraints: constraints)
        
        var accumulatedResult: VitalLensResult?
        var currentState: (any InferenceState)? = nil
        var totalFramesProcessed = 0
        
        for await frame in source.frames() {
            // Timestamp is frame index / fps
            let timestamp = Double(totalFramesProcessed) / nominalFPS
            
            let context = InferenceContext(
                timestamp: timestamp,
                orientation: source.orientation,
                isMirrored: false,
                roi: roi
            )
            
            // Transform: Crop/Scale/Convert to RGB Data
            // In the future, this could use a FrameTransformer if we needed local inference on files.
            // For now, we assume API behavior (RGB Data).
            if let bytes = try? processor.process(
                pixelBuffer: frame.buffer,
                roi: roi,
                targetSize: config.inputSize
            ) {
                await buffer.append(unit: .rgbData(bytes), context: context)
            }
            
            totalFramesProcessed += 1
            
            if await buffer.isReady(hasState: currentState != nil, mode: .file) {
                if let window = await buffer.consume() {
                    let (result, newState) = try await strategy.infer(
                        window: window,
                        state: currentState,
                        mode: .file,
                        model: nil
                    )
                    currentState = newState
                    
                    if accumulatedResult == nil {
                        accumulatedResult = result
                    } else {
                        // Aggregate signals using the VitalsEstimateManager logic
                        accumulatedResult = await vitalsEstimator.process(
                            chunk: result,
                            mode: .complete,
                            config: config
                        )
                    }
                }
            }
        }
        
        // Handle remaining frames (Flush final partial batch)
        if let window = await buffer.consume(), window.count >= config.nInputs {
            let (result, _) = try await strategy.infer(
                window: window,
                state: currentState,
                mode: .file,
                model: nil
            )
            if accumulatedResult == nil {
                accumulatedResult = result
            } else {
                accumulatedResult = await vitalsEstimator.process(
                    chunk: result,
                    mode: .complete,
                    config: config
                )
            }
        }
        
        guard var final = accumulatedResult else {
            throw VitalLensError.processingError("Video too short or no result generated.")
        }
        
        // Robustly determine count (fallback to time array length if sampleCount is nil)
        var count = final.sampleCount ?? final.time.count
        if count == 0, let firstSignal = final.signals.values.first {
            count = firstSignal.data.count
        }
        
        if count > 0 {
            let duration = Double(count) / nominalFPS
            // Generate clean, evenly spaced timestamps based on file FPS
            let timeSteps = stride(from: 0.0, to: duration, by: 1.0 / nominalFPS)
            
            final = VitalLensResult(
                face: final.face,
                signals: final.signals,
                time: Array(timeSteps),
                fps: nominalFPS,
                modelUsed: final.modelUsed,
                state: final.state,
                message: final.message,
                sampleCount: count
            )
        }
        
        return final
    }
}