import Foundation
import VitalLensCore
import VitalLensInference
import CoreVideo

/// Handles the two-pass processing of video files for high-accuracy vital sign estimation.
///
/// - Pass 1 (Scanning): Iterates through the video to detect faces and calculate a stable, global ROI.
/// - Pass 2 (Inference): Processes frames using the stable ROI and batches them for the inference strategy.
actor FileProcessor {
    
    private let url: URL
    private let processor: ImageProcessor
    private let detector: any FaceDetecting
    
    init(url: URL, detector: any FaceDetecting = FaceDetector()) {
        self.url = url
        self.detector = detector
        self.processor = ImageProcessor()
    }
    
    /// Execute the full processing pipeline.
    func process(strategy: any InferenceStrategy, globalROI: CGRect? = nil) async throws -> VitalLensResult {
        // 1. Resolve Configs
        let config = try await strategy.resolveConfig()
        let bufConfig = try await strategy.bufferConfig
        
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
            bufConfig: bufConfig,
            strategy: strategy
        )
    }
    
    // MARK: - Pass 1: Scanning
    
    /// Scans the video to determine a stable "Median Face" and derives the ROI.
    private func performScanningPass(config: ModelConfig) async throws -> CGRect {
        let source = try await FileSource.from(url: url)
        
        // We optimize by checking only a subset of frames (e.g. 1 Hz stride)
        // This is significantly faster than running face detection on every frame.
        let stride = max(1, Int(source.nominalFrameRate * 1.0))
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
                targetSize: config.inputSize
            ) {
                buffer.append(unit: .rgbData(bytes), context: context)
            }
            
            totalFramesProcessed += 1
            print("framesProcessed: \(totalFramesProcessed)")

            // 1. SAFETY CLAMP: Only batch if fileMax > 0, and ensure keep <= take
            if bufConfig.fileMax > 0 && buffer.count >= bufConfig.fileMax {
                let take = UInt32(bufConfig.fileMax)
                let keep = bufConfig.overlap
                
                let command = InferenceCommand(bufferId: "file", takeCount: take, keepCount: keep)
                
                if let window = buffer.execute(command: command) {
                    let (result, newState) = try await strategy.infer(window: window, state: currentState, mode: .file, model: nil)
                    currentState = newState
                    _ = session.process(input: result.toSessionInput(), mode: .incremental)
                }
            }
        }
        
        var finalMessage: String?
        var finalModelUsed: String? // 2. METADATA FIX: Track model used
        
        if buffer.count >= config.nInputs {
            let command = InferenceCommand(bufferId: "file", takeCount: UInt32(buffer.count), keepCount: 0)
            if let window = buffer.execute(command: command) {
                let (result, _) = try await strategy.infer(window: window, state: currentState, mode: .file, model: nil)
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
