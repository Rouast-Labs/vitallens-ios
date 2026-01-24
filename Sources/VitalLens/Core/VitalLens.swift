import Foundation
import CoreGraphics

/// The primary client for the VitalLens API.
///
/// Use this class to configure your session, manage real-time scanning, or process video files.
///
///     let client = VitalLens(apiKey: "your_key", method: .vitalLens2)
public final class VitalLens: @unchecked Sendable {
    
    // MARK: - Types
    
    /// The estimation method to use.
    public enum Method: String, Sendable, CaseIterable {
        /// The recommended method. Automatically selects the best model for your plan.
        case vitalLens = "vitallens"
        /// Forces the use of the VitalLens 2.0 model (High accuracy, HRV).
        case vitalLens2 = "vitallens-2.0"
        /// Forces the use of the VitalLens 1.1 model (Standard accuracy).
        case vitalLens1_1 = "vitallens-1.1"
        /// Forces the use of the VitalLens 1.0 model.
        case vitalLens1 = "vitallens-1.0"
        
        /// Returns true if this method supports Heart Rate Variability (HRV).
        public var supportsHRV: Bool {
            switch self {
            case .vitalLens, .vitalLens2: return true
            default: return false
            }
        }
    }
    
    // MARK: - Configuration
    
    /// The API key for authentication.
    /// Not required if using a `proxyURL`.
    public let apiKey: String?
    
    /// The estimation method to use.
    public let method: Method
    
    /// The URL of your backend proxy (if used to hide the API Key).
    /// If set, the client will send requests here instead of `api.rouast.com`.
    public let proxyURL: URL?
    
    /// The frequency (in Hz) at which face detection should be performed during live streams.
    /// Default is 1.0 Hz.
    public let faceDetectionFrequency: Double
    
    /// Optional global region of interest (ROI) to skip face detection.
    /// If set, this region is used for every frame (normalized coordinates 0.0 - 1.0).
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
    
    // MARK: - internal
    // Future: StreamProcessor and APIClient properties will live here.
}
