import Foundation
import CoreVideo
import ImageIO
import VitalLensCore

/// A thread-safe wrapper for CVPixelBuffer
public struct SendablePixelBuffer: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Represents the unit of data to be processed.
/// - `rgbData`: Pre-processed, flattened RGB bytes (e.g. 40x40x3). Used for the Remote API.
/// - `pixelBuffer`: Raw image buffer. Used for Local CoreML.
public enum InferenceUnit: Sendable {
    case rgbData(Data)
    case pixelBuffer(SendablePixelBuffer)
}

/// Contextual metadata associated with a specific frame unit.
public struct InferenceContext: Sendable {
    public let timestamp: TimeInterval    
    public let orientation: CGImagePropertyOrientation
    public let isMirrored: Bool
    public let roi: CGRect
    
    public init(
        timestamp: TimeInterval,
        orientation: CGImagePropertyOrientation = .up,
        isMirrored: Bool = false,
        roi: CGRect = .zero
    ) {
        self.timestamp = timestamp
        self.orientation = orientation
        self.isMirrored = isMirrored
        self.roi = roi
    }
}

public protocol InferenceState: Sendable {}

/// Defines an abstract backend for estimating vital signs.
public protocol InferenceStrategy: Sendable {

    /// Defines the buffering limits for this specific strategy.
    var bufferConfig: VitalLensCore.BufferConfig { get async throws }
    
    /// Resolves the model configuration (input size, FPS, etc.) required by this strategy.
    func resolveConfig() async throws -> ModelConfig
    
    /// Processes a window of frames and returns the estimated time-series signals.
    ///
    /// - Parameters:
    ///   - window: A list of frame units and their context.
    ///   - state: The opaque RNN state from the previous inference (if any).
    ///   - mode: Whether this is a live stream or a file dump.
    ///   - model: Optional model identifier override.
    func infer(
        window: [(InferenceUnit, InferenceContext)], 
        state: (any InferenceState)?, 
        mode: InferenceMode, 
        model: String?
    ) async throws -> (result: VitalLensResult, newState: (any InferenceState)?)
}
