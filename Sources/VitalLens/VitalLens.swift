import Foundation
import CoreGraphics
import VitalLensCore
import VitalLensInference

#if canImport(UIKit)
import UIKit
#endif

/// The primary client for the VitalLens API.
public final class VitalLens: @unchecked Sendable {

    var streamProcessor: StreamProcessor?

    // Observers for lifecycle management
    private var observers: [NSObjectProtocol] = []
    
    // MARK: - Configuration
    public let apiKey: String?
    public let method: String
    public let proxyURL: URL?
    public let faceDetectionFrequency: Double
    public let globalROI: CGRect?
    public let overrideFps: Double?
    public let waveformMode: WaveformMode

    /// Closure triggered instantly when a face enters or leaves the camera frame.
    public var onFaceStateChanged: (@Sendable (Bool) -> Void)? {
        didSet {
            let cb = onFaceStateChanged
            Task { await streamProcessor?.setFaceStateCallback(cb) }
        }
    }

    private let strategy: any InferenceStrategy
    private let customSource: (any CameraStreaming)?
    
    // MARK: - Initialization
    
    /// Initializes a new VitalLens client.
    ///
    /// - Parameters:
    ///   - apiKey: Your VitalLens API Key (required if proxyUrl is not set).
    ///   - method: The estimation method to use. Defaults to `"vitallens"`.
    ///   - faceDetectionFrequency: Frequency in Hz to run face detection (default 1.0).
    ///   - globalROI: A fixed region of interest (normalized 0.0-1.0) to use instead of face detection.
    ///   - proxyURL: Optional URL to your backend proxy. If set, `apiKey` is ignored by the client (your server must add it).
    public init(
        apiKey: String? = nil,
        method: String = "vitallens",
        faceDetectionFrequency: Double = 1.0,
        globalROI: CGRect? = nil,
        proxyURL: URL? = nil,
        overrideFps: Double? = nil,
        waveformMode: WaveformMode = .incremental
    ) {
        self.apiKey = apiKey
        self.method = method
        self.faceDetectionFrequency = faceDetectionFrequency
        self.globalROI = globalROI
        self.proxyURL = proxyURL
        self.overrideFps = overrideFps
        self.waveformMode = waveformMode
        self.customSource = nil
        
        let requestedModelName = method == "vitallens" ? nil : method
        self.strategy = APIInference(
            apiKey: apiKey,
            proxyURL: proxyURL,
            requestedModel: requestedModelName,
            overrideFps: overrideFps
        )

        setupLifecycleObservers()
    }

    public init(
        source: any CameraStreaming,
        strategy: any InferenceStrategy,
        waveformMode: WaveformMode = .incremental
    ) {
        self.apiKey = nil
        self.method = "vitallens"
        self.faceDetectionFrequency = 1.0
        self.globalROI = nil
        self.proxyURL = nil
        self.overrideFps = nil
        self.waveformMode = waveformMode
        self.customSource = source
        self.strategy = strategy
        
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
        self.waveformMode = .incremental
        
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
            streamProcessor = StreamProcessor(
                strategy: strategy,
                camera: customSource,
                waveformMode: self.waveformMode
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

    public func stopStream() {
        Task {
            await streamProcessor?.stop()
        }
    }
    
    public func processVideoFile(at url: URL) async throws -> VitalLensResult {
        let processor = FileProcessor(url: url)
        return try await processor.process(strategy: strategy, globalROI: globalROI)
    }
}
