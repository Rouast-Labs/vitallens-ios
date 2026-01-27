import Foundation
import UIKit

/// The primary client for the VitalLens API.
public final class VitalLens: @unchecked Sendable {
    
    // MARK: - Types
    public enum Method: String, Sendable, CaseIterable {
        case vitalLens = "vitallens"
        case vitalLens2 = "vitallens-2.0"
        case vitalLens1_1 = "vitallens-1.1"
        case vitalLens1 = "vitallens-1.0"
        
        public var supportsHRV: Bool {
            switch self {
            case .vitalLens, .vitalLens2: return true
            default: return false
            }
        }
    }
    
    // MARK: - Configuration
    public let apiKey: String?
    public let method: Method
    public let proxyURL: URL?
    public let faceDetectionFrequency: Double
    public let globalROI: CGRect?
    
    // MARK: - Internal Dependencies
    // We keep the processor alive as long as the client exists or until stopped.
    private var streamProcessor: StreamProcessor?
    
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
    }
    
    // MARK: - Public API
    
    /// Starts the live camera stream and returns an async sequence of results.
    ///
    /// - Parameter preview: An optional UIView where the camera feed should be rendered.
    /// - Returns: An AsyncStream of `VitalLensResult` updates.
    public func startStream(preview: UIView? = nil) async throws -> AsyncStream<VitalLensResult> {
        // Initialize the processor if needed
        if streamProcessor == nil {
            streamProcessor = StreamProcessor(apiKey: apiKey, proxyURL: proxyURL)
        }
        
        guard let processor = streamProcessor else {
            throw VitalLensError.processingError("Failed to initialize StreamProcessor")
        }
        
        return try await processor.start(preview: preview)
    }
    
    /// Stops the live camera stream and releases resources.
    public func stopStream() {
        Task {
            await streamProcessor?.stop()
            streamProcessor = nil
        }
    }
    
    /// Processes a video file from a URL.
    /// Note: Implementation pending FileSource logic.
    public func processVideoFile(at url: URL) async throws -> VitalLensResult {
        // TODO: Implement FileSource and connect to StreamProcessor or separate FileProcessor
        throw VitalLensError.processingError("File processing not yet implemented")
    }
}