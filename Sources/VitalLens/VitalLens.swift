import Foundation
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
    }

    init(processor: StreamProcessor) {
        self.apiKey = "test"
        self.method = .vitalLens
        self.faceDetectionFrequency = 1.0
        self.globalROI = nil
        self.proxyURL = nil
        self.streamProcessor = processor
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
    
    /// Processes a video file from a URL.
    /// Note: Implementation pending FileSource logic.
    public func processVideoFile(at url: URL) async throws -> VitalLensResult {
        // TODO: Implement FileSource and connect to StreamProcessor or separate FileProcessor
        throw VitalLensError.processingError("File processing not yet implemented")
    }
}