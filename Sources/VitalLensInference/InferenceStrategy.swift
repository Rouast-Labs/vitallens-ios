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

/// Defines the buffering constraints for a specific strategy.
public struct BatchConstraints: Sendable {
    // Hardcoded infrastructure constants
    private static let maxBase64BytesForFrames = 5_760_000
    private static let maxStreamPolicyFrames = 150
    private static let base64Overhead = 1.3333

    private let minNoState: Int
    private let minWithState: Int
    public let streamMax: Int
    public let fileMax: Int
    
    public init(for config: ModelConfig) {
        // Determine minimums
        self.minWithState = config.nInputs
        self.minNoState = max(16, config.nInputs)
        
        // Calculate physical max based on payload constraints
        let bytesPerFrame = config.inputSize * config.inputSize * 3
        let rawCapacityBytes = Double(Self.maxBase64BytesForFrames) / Self.base64Overhead
        let calculatedMax = Int(floor(rawCapacityBytes / Double(bytesPerFrame)))
        
        // Assign Mode-specific maximums
        self.fileMax = calculatedMax
        self.streamMax = min(Self.maxStreamPolicyFrames, calculatedMax)
    }

    public init(minNoState: Int, minWithState: Int, streamMax: Int, fileMax: Int = 0) {
        self.minNoState = minNoState
        self.minWithState = minWithState
        self.streamMax = streamMax
        self.fileMax = fileMax
    }
    
    public func minToSend(hasState: Bool) -> Int {
        return hasState ? minWithState : minNoState
    }

    public func maxToSend(mode: InferenceMode) -> Int {
        switch mode {
        case .stream:
            return streamMax
        case .file:
            return fileMax
        }
    }

    public func optimalToSend(mode: InferenceMode, hasState: Bool) -> Int {
        switch mode {
        case .stream:
            // Low latency: send as soon as valid
            return hasState ? minWithState : minNoState
        case .file:
            // High throughput: wait until batch is full
            return fileMax
        }
    }
}

public protocol InferenceState: Sendable {}

/// Defines an abstract backend for estimating vital signs.
public protocol InferenceStrategy: Sendable {

    /// Defines the buffering limits for this specific strategy.
    var batchConstraints: BatchConstraints { get async throws }
    
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
