import Foundation
import CoreGraphics
import VitalLensCore
import VitalLensInference

#if canImport(UIKit)
import UIKit
#endif

/// The primary client for the VitalLens API and local inference.
/// Handles initialization, configuration, and stream lifecycle management.
public final class VitalLens: @unchecked Sendable {

    var streamProcessor: StreamProcessor?

    private var observers: [NSObjectProtocol] = []
    
    public let apiKey: String?
    public let method: String
    public let proxyURL: URL?
    public let faceDetectionFrequency: Double
    public let globalROI: CGRect?
    public let overrideFps: Double?
    public let waveformMode: WaveformMode
    public let debugMode: Bool

    /// A closure triggered instantly when a face enters or leaves the camera frame.
    public var onFaceStateChanged: (@Sendable (Bool) -> Void)? {
        didSet {
            let cb = onFaceStateChanged
            Task { await streamProcessor?.setFaceStateCallback(cb) }
        }
    }

    private let strategy: any InferenceStrategy
    private let customSource: (any CameraStreaming)?
    private let customTransformer: FrameTransformer?
    
    /// Initializes a new VitalLens client.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key (required if proxyURL is not set and using API inference).
    ///   - method: The estimation method to use. Defaults to `"vitallens"`.
    ///   - faceDetectionFrequency: Frequency in Hz to run face detection. Defaults to `1.0`.
    ///   - globalROI: A fixed region of interest (normalized 0.0-1.0) to use instead of face detection.
    ///   - proxyURL: Optional URL to your backend proxy. If set, `apiKey` is ignored.
    ///   - overrideFps: Target FPS to sample the camera at. Overrides the model's default FPS if set.
    ///   - waveformMode: How waveforms are returned: `.incremental` or `.global`. Defaults to `.incremental`.
    ///   - debugMode: If true, exposes intermediate frame crops. Defaults to `false`.
    ///   - source: A custom camera or frame source. Defaults to standard `CameraSource`.
    ///   - strategy: A custom inference strategy. Defaults to `APIInference` using provided key/proxy.
    ///   - transformer: An optional custom closure to preprocess frames before inference.
    public init(
        apiKey: String? = nil,
        method: String = "vitallens",
        faceDetectionFrequency: Double = 1.0,
        globalROI: CGRect? = nil,
        proxyURL: URL? = nil,
        overrideFps: Double? = nil,
        waveformMode: WaveformMode = .incremental,
        debugMode: Bool = false,
        source: (any CameraStreaming)? = nil,
        strategy: (any InferenceStrategy)? = nil,
        transformer: FrameTransformer? = nil
    ) {
        self.apiKey = apiKey
        self.method = method
        self.faceDetectionFrequency = faceDetectionFrequency
        self.globalROI = globalROI
        self.proxyURL = proxyURL
        self.overrideFps = overrideFps
        self.waveformMode = waveformMode
        self.debugMode = debugMode        
        self.customSource = source
        self.customTransformer = transformer
        
        if let providedStrategy = strategy {
            self.strategy = providedStrategy
        } else {
            let requestedModelName = method == "vitallens" ? nil : method
            self.strategy = APIInference(
                apiKey: apiKey,
                proxyURL: proxyURL,
                requestedModel: requestedModelName,
                overrideFps: overrideFps
            )
        }

        setupLifecycleObservers()
    }

    /// Internal init for testing
    internal init(processor: StreamProcessor) {
        self.apiKey = "test"
        self.method = "vitallens-2.0"
        self.faceDetectionFrequency = 0.5
        self.globalROI = nil
        self.proxyURL = nil
        self.overrideFps = nil
        self.streamProcessor = processor 
        self.strategy = APIInference(apiKey: "test") 
        self.customSource = nil
        self.debugMode = false
        self.waveformMode = .incremental
        self.customTransformer = nil
        
        setupLifecycleObservers()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    private func setupLifecycleObservers() {
        #if canImport(UIKit)
        let center = NotificationCenter.default
        
        let backgroundObserver = center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.handleAppBackground()
        }
        
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
    /// Starts the live camera stream and begins the inference loop.
    ///
    /// - Parameter preview: An optional `UIView` to render the live camera feed.
    /// - Returns: An asynchronous stream yielding continuous `VitalLensResult` updates.
    /// - Throws: `VitalLensError` if camera access is denied or stream initialization fails.
    public func startStream(preview: UIView? = nil) async throws -> AsyncStream<VitalLensResult> {
        return try await _startStream(preview: preview)
    }
    #else
    /// Starts the stream in headless mode (no camera preview).
    ///
    /// - Returns: An asynchronous stream yielding continuous `VitalLensResult` updates.
    /// - Throws: `VitalLensError` if initialization fails.
    public func startStream() async throws -> AsyncStream<VitalLensResult> {
        return try await _startStream(preview: nil)
    }
    #endif
    
    private func _startStream(preview: Any?) async throws -> AsyncStream<VitalLensResult> {
        if streamProcessor == nil {
            streamProcessor = StreamProcessor(
                strategy: strategy,
                camera: customSource,
                transformer: customTransformer,
                waveformMode: self.waveformMode,
                debugMode: self.debugMode
            )
        }
        
        guard let processor = streamProcessor else {
            throw VitalLensError.processingError("Failed to initialize StreamProcessor")
        }
        
        await processor.setFaceStateCallback(self.onFaceStateChanged)
                
        var wrapper: SendableUIPreview? = nil
        if let view = preview {
            wrapper = SendableUIPreview(view)
        }
        
        return try await processor.start(preview: wrapper)
    }

    /// Resets the internal data buffers without stopping the camera.
    /// Useful for forcing a new estimation window when the subject changes abruptly.
    public func resetStream() {
        Task {
            await streamProcessor?.reset()
        }
    }

    /// Stops the active camera session, terminates the background inference loop, and clears internal buffers.
    public func stopStream() {
        Task {
            await streamProcessor?.stop()
        }
    }
    
    /// Processes a local video file in batch mode.
    ///
    /// - Parameter url: The local file URL of the video to process.
    /// - Returns: A complete `VitalLensResult` containing the time-series estimates for the entire file.
    /// - Throws: `VitalLensError` if file reading, face detection, or inference fails.
    public func processVideoFile(at url: URL) async throws -> VitalLensResult {
        let processor = FileProcessor(url: url)
        return try await processor.process(strategy: strategy, globalROI: globalROI)
    }
}

public extension VitalLens {
    var debugLatestCrop: CGImage? {
        return streamProcessor?.debugImage
    }
}
