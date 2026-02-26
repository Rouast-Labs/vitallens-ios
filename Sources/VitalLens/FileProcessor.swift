import Foundation
import VitalLensCore
import VitalLensInference
import CoreVideo

/// Handles the two-pass processing of video files for vital sign estimation.
///
/// - Pass 1 (Scanning): Iterates through the video to detect faces and calculate a stable, global ROI.
/// - Pass 2 (Inference): Processes frames using the stable ROI and batches them for the inference strategy.
actor FileProcessor {
    
    private let url: URL
    private let processor: ImageProcessor
    private let detector: any FaceDetecting
    
    /// Initializes a new FileProcessor.
    ///
    /// - Parameters:
    ///   - url: The local file URL of the video to process.
    ///   - detector: The face detection strategy to use. Defaults to `FaceDetector()`.
    init(url: URL, detector: any FaceDetecting = FaceDetector()) {
        self.url = url
        self.detector = detector
        self.processor = ImageProcessor()
    }
    
    /// Executes the full processing pipeline on the video file.
    ///
    /// - Parameters:
    ///   - strategy: The inference strategy used to estimate vital signs.
    ///   - globalROI: An optional fixed region of interest. If provided, skips the scanning pass.
    /// - Returns: The aggregated `VitalLensResult` containing the estimated vital signs and waveforms.
    /// - Throws: `VitalLensError` if processing, face detection, or inference fails.
    func process(strategy: any InferenceStrategy, globalROI: CGRect? = nil) async throws -> VitalLensResult {
        let config = try await strategy.resolveConfig()
        let bufConfig = try await strategy.bufferConfig
        
        let finalROI: CGRect
        if let provided = globalROI {
            finalROI = provided
        } else {
            finalROI = try await performScanningPass(config: config)
        }
        
        return try await performInferencePass(
            roi: finalROI,
            config: config,
            bufConfig: bufConfig,
            strategy: strategy
        )
    }
        
    /// Scans the video to determine a stable "Median Face" and derives the overall region of interest.
    ///
    /// - Parameter config: The resolved model configuration.
    /// - Returns: The calculated stable ROI across the video.
    /// - Throws: `VitalLensError` if no face is detected in the video.
    private func performScanningPass(config: ModelConfig) async throws -> CGRect {
        let source = try await FileSource.from(url: url)
        
        let stride = max(1, Int(source.nominalFrameRate * 1.0))
        var frameCount = 0
        var detections: [CGRect] = []
        
        for await frame in source.frames() {
            frameCount += 1
            if frameCount % stride != 0 { continue }
            
            if let rect = try? await detector.detectFace(in: frame, orientation: source.orientation, isMirrored: false) {
                detections.append(rect)
            }
        }
        
        guard !detections.isEmpty else {
            throw VitalLensError.processingError("No face detected in video file.")
        }
        
        let totalX = detections.reduce(0) { $0 + $1.midX }
        let totalY = detections.reduce(0) { $0 + $1.midY }
        let centroid = CGPoint(x: totalX / CGFloat(detections.count), y: totalY / CGFloat(detections.count))
        
        let bestFace = detections.min { a, b in
            let distA = hypot(a.midX - centroid.x, a.midY - centroid.y)
            let distB = hypot(b.midX - centroid.x, b.midY - centroid.y)
            return distA < distB
        } ?? detections[0]
        
        return ROICalculator.calculateROI(from: bestFace, method: config.roiMethod)
    }
        
    /// Reads the video linearly, applies the fixed ROI, and performs batched inference.
    ///
    /// - Parameters:
    ///   - roi: The fixed region of interest to apply to all frames.
    ///   - config: The model configuration dictating input size and model characteristics.
    ///   - bufConfig: The buffer configuration dictating batch sizes.
    ///   - strategy: The inference strategy to execute.
    /// - Returns: The final aggregated `VitalLensResult`.
    /// - Throws: `VitalLensError` if inference fails.
    private func performInferencePass(
        roi: CGRect,
        config: ModelConfig,
        bufConfig: VitalLensCore.BufferConfig,
        strategy: any InferenceStrategy
    ) async throws -> VitalLensResult {
        
        let source = try await FileSource.from(url: url)
        let nominalFPS = Double(source.nominalFrameRate)
        
        let buffer = FrameBuffer(id: "file", roi: roi, mode: .file, config: config, timestamp: 0.0)
        let session = VitalLensCore.Session(config: config.toSessionConfig())
        
        var currentState: (any InferenceState)? = nil
        var totalFramesProcessed = 0
        
        for await frame in source.frames() {
            let timestamp = Double(totalFramesProcessed) / nominalFPS
            
            let context = InferenceContext(
                timestamp: timestamp,
                orientation: source.orientation,
                isMirrored: false,
                roi: roi
            )
            
            if let bytes = try? processor.process(
                pixelBuffer: frame.buffer,
                roi: roi,
                targetSize: config.inputSize,
                orientation: source.orientation,
                isMirrored: false
            ) {
                buffer.append(unit: .rgbData(bytes), context: context)
            }
            
            totalFramesProcessed += 1

            if bufConfig.fileMax > 0 && buffer.count >= bufConfig.fileMax {
                let take = UInt32(bufConfig.fileMax)
                let keep = bufConfig.overlap
                
                let command = InferenceCommand(bufferId: "file", takeCount: take, keepCount: keep)
                
                if let window = buffer.execute(command: command) {
                    let (result, newState) = try await strategy.infer(window: window, state: currentState, mode: .file, model: config.modelName)
                    currentState = newState
                    _ = session.process(input: result.toSessionInput(), mode: .incremental)
                }
            }
        }
        
        var finalMessage: String?
        var finalModelUsed: String?
        
        if buffer.count >= config.nInputs {
            let command = InferenceCommand(bufferId: "file", takeCount: UInt32(buffer.count), keepCount: 0)
            if let window = buffer.execute(command: command) {
                let (result, _) = try await strategy.infer(window: window, state: currentState, mode: .file, model: config.modelName)
                _ = session.process(input: result.toSessionInput(), mode: .incremental)
                finalMessage = result.message
                finalModelUsed = result.modelUsed
            }
        }
        
        let emptyInput = SessionInput(face: nil, signals: [:], timestamp: [])
        let globalResult = session.process(input: emptyInput, mode: .global)
        return globalResult.toVitalLensResult(originalState: nil as StateData?, message: finalMessage, modelUsed: finalModelUsed)
    }
}
