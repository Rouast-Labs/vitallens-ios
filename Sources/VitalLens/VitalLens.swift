import Foundation
import CoreGraphics
import VitalLensCore

#if canImport(UIKit)
import UIKit
#endif

/// The primary client for the VitalLens API.
public final class VitalLens: @unchecked Sendable {
    
    // MARK: - Types
    public enum Method: String, Sendable, CaseIterable {
        case vitalLens = "vitallens"
        case vitalLens2 = "vitallens-2.0"
        case vitalLens1_1 = "vitallens-1.1"
        case vitalLens1 = "vitallens-1.0"
    }

    var streamProcessor: StreamProcessor?

    // Observers for lifecycle management
    private var observers: [NSObjectProtocol] = []
    
    // MARK: - Configuration
    public let apiKey: String?
    public let method: Method
    public let proxyURL: URL?
    public let faceDetectionFrequency: Double
    public let globalROI: CGRect?
    
    // MARK: - Initialization
    
    /// Initializes a new VitalLens client.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key (required if proxyUrl is not set).
    ///   - method: The estimation method to use. Defaults to `.vitalLens`.
    ///   - faceDetectionFrequency: Frequency in Hz to run face detection (default 1.0).
    ///   - globalROI: A fixed region of interest (normalized 0.0-1.0) to use instead of face detection.
    ///   - proxyURL: Optional URL to your backend proxy. If set, `apiKey` is ignored by the client (your server must add it).
    public init(
        apiKey: String? = nil,
        method: Method = .vitalLens,
        faceDetectionFrequency: Double = 1.0,
        globalROI: CGRect? = nil,
        proxyURL: URL? = nil
    ) {
        self.apiKey = apiKey
        self.method = method
        self.faceDetectionFrequency = faceDetectionFrequency
        self.globalROI = globalROI
        self.proxyURL = proxyURL

        setupLifecycleObservers()
    }

    init(processor: StreamProcessor) {
        self.apiKey = "test"
        self.method = .vitalLens
        self.faceDetectionFrequency = 1.0
        self.globalROI = nil
        self.proxyURL = nil
        self.streamProcessor = processor

        setupLifecycleObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        
        // Pause on background
        let backgroundObserver = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleAppBackground()
        }
        
        // Resume on foreground
        let foregroundObserver = center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleAppForeground()
        }
        
        observers.append(contentsOf: [backgroundObserver, foregroundObserver])
        #endif
    }

    private func handleAppBackground() {
        Task {
            await streamProcessor?.pause()
        }
    }
    
    private func handleAppForeground() {
        Task {
            try? await streamProcessor?.resume()
        }
    }
    
    // MARK: - Public API
    
    #if canImport(UIKit)
    /// Starts the live camera stream.
    public func startStream(preview: UIView? = nil) async throws -> AsyncStream<VitalLensResult> {
        return try await _startStream(preview: preview)
    }
    #else
    /// Starts the stream in headless/test mode (no camera).
    public func startStream() async throws -> AsyncStream<VitalLensResult> {
        return try await _startStream(preview: nil)
    }
    #endif
    
    private func _startStream(preview: Any?) async throws -> AsyncStream<VitalLensResult> {
        if streamProcessor == nil {
            let apiClient = APIClient(apiKey: apiKey, proxyURL: proxyURL)
            streamProcessor = StreamProcessor(strategy: apiClient)
        }
        
        guard let processor = streamProcessor else {
            throw VitalLensError.processingError("Failed to initialize StreamProcessor")
        }
        
        var wrapper: SendableUIPreview? = nil
        if let view = preview {
            wrapper = SendableUIPreview(view)
        }
        
        return try await processor.start(preview: wrapper)
    }

    public func stopStream() {
        Task {
            await streamProcessor?.stop()
        }
    }
    
    public func processVideoFile(at url: URL) async throws -> VitalLensResult {
        // 1. Setup Source
        let source = try await FileSource.from(url: url)

        // 2. Resolve Config
        let apiClient = APIClient(apiKey: apiKey, proxyURL: proxyURL)
        let config = try await apiClient.resolveConfig()
        
        // 3. Components
        let processor = ImageProcessor()
        let detector = FaceDetector()
        _ = BufferManager()
        let vitalsManager = VitalsEstimateManager()
        
        var roi: CGRect? = self.globalROI
        var aggregatedResult: VitalLensResult?
        var state: [Float]?
        
        // Iterate frames
        for await frame in source.frames() {
            if roi == nil {
                do {
                    if let detectedRect = try await detector.detectFace(
                        in: frame, 
                        orientation: source.orientation
                    ) {
                        let idealROI = ROICalculator.calculateROI(from: detectedRect, method: config.roiMethod)
                        roi = idealROI
                        print("[VitalLens] File Processing ROI established: \(idealROI)")
                        break
                    }
                } catch {
                    print("[VitalLens] Face Detection Failed: \(error)")
                }
            }
        }
        
        var chunkData = Data()
        let frameSize = config.inputSize * config.inputSize * 3
        let batchSize = 900
        let overlapFrames = config.nInputs - 1
        var totalFramesProcessed = 0
        
        // Reset iterator
        let freshSource = try await FileSource.from(url: url)
        
        for await frame in freshSource.frames() {
            
            // Detection on first frame only
            if roi == nil {
                if let rect = try? await detector.detectFace(in: frame) {
                    roi = ROICalculator.calculateROI(from: rect, method: config.roiMethod)
                } else { continue }
            }
            
            guard let activeROI = roi else { continue }
            
            let bytes = try processor.process(pixelBuffer: frame.buffer, roi: activeROI, targetSize: config.inputSize)
            chunkData.append(bytes)
            totalFramesProcessed += 1
            
            // Check if we have a full batch
            let currentFrameCount = chunkData.count / frameSize
            
            if currentFrameCount >= batchSize {
                // SEND CHUNK
                let result = try await apiClient.processVideoChunk(
                    rawRGBBytes: chunkData,
                    metadata: ["fps": String(source.nominalFrameRate)],
                    state: state
                )
                
                // Update State
                if let stateStr = result.state?.data,
                   let data = Data(base64Encoded: stateStr) {
                    state = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                }
                
                // Aggregate Result
                if aggregatedResult == nil {
                    aggregatedResult = result
                } else {
                    // Merge logic needed here (VitalsEstimateManager handles this)
                    aggregatedResult = await vitalsManager.process(chunk: result, mode: .complete, config: config)
                }
                
                // Prepare Next Chunk (Retain Overlap)
                let bytesToKeep = overlapFrames * frameSize
                let suffix = chunkData.suffix(bytesToKeep)
                chunkData = Data(suffix)
            }
        }
        
        // Process remaining frames
        if chunkData.count >= (config.nInputs * frameSize) {
             let result = try await apiClient.processVideoChunk(
                rawRGBBytes: chunkData,
                metadata: ["fps": String(source.nominalFrameRate)],
                state: state
            )
            aggregatedResult = await vitalsManager.process(chunk: result, mode: .complete, config: config)
        }
        
        guard let final = aggregatedResult else {
            throw VitalLensError.processingError("No valid result generated (video might be too short or no face detected)")
        }
        
        return final
    }
}