import Foundation
import CoreVideo
import ImageIO

/// Defines the target endpoint behavior.
public enum InferenceMode: Sendable {
    case stream 
    case file
}

/// Represents the unit of data to be processed.
/// - `rgbData`: Pre-processed, flattened RGB bytes (e.g. 40x40x3). Used for the Remote API.
/// - `pixelBuffer`: Raw image buffer. Used for Local CoreML (Future).
public enum InferenceUnit: Sendable {
    case rgbData(Data)
    case pixelBuffer(CVPixelBuffer)
}

/// Contextual metadata associated with a specific frame unit.
public struct InferenceContext: Sendable {
    public let timestamp: TimeInterval
    
    // Future-proofing: CoreML models often need orientation/mirroring flags passed in at inference time
    public let orientation: CGImagePropertyOrientation
    public let isMirrored: Bool
    
    // The specific ROI used to generate this unit
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
/// These values dictate when the BufferManager should trigger a ready state or force a flush.
// TODO: These could depend on the model too, though.
public struct BatchConstraints: Sendable {
    /// The minimum number of frames required to process a stream batch without state (Cold Start).
    public let streamMinNoState: Int
    /// The minimum number of frames required to process a stream batch with state (Steady State).
    public let streamMinWithState: Int
    /// The maximum number of frames allowed in a stream batch (Latency Ceiling).
    public let streamMax: Int
    
    /// The minimum number of frames required to process a file batch without state.
    public let fileMinNoState: Int
    /// The minimum number of frames required to process a file batch with state.
    public let fileMinWithState: Int
    /// The maximum number of frames allowed in a file batch (Payload Size Ceiling).
    public let fileMax: Int
    
    public init(
        streamMinNoState: Int = 16,
        streamMinWithState: Int = 4, // Default nInputs
        streamMax: Int = 150,
        fileMinNoState: Int = 16,
        fileMinWithState: Int = 4,   // Default nInputs
        fileMax: Int = 900
    ) {
        self.streamMinNoState = streamMinNoState
        self.streamMinWithState = streamMinWithState
        self.streamMax = streamMax
        self.fileMinNoState = fileMinNoState
        self.fileMinWithState = fileMinWithState
        self.fileMax = fileMax
    }
    
    /// Returns the ideal batch size for the current context.
    public func threshold(mode: InferenceMode, hasState: Bool) -> Int {
        switch mode {
        case .stream:
            return hasState ? streamMinWithState : streamMinNoState
        case .file:
            return hasState ? fileMinWithState : fileMinNoState
        }
    }
    
    /// Returns the hard overflow limit for the current context.
    public func maxLimit(mode: InferenceMode) -> Int {
        switch mode {
        case .stream: return streamMax
        case .file: return fileMax
        }
    }
}

public protocol InferenceState: Sendable {}

/// Defines an abstract backend for estimating vital signs.
public protocol InferenceStrategy: Sendable {

    /// Defines the buffering limits for this specific strategy.
    var batchConstraints: BatchConstraints { get }
    
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

public struct CoreMLAuxiliaryData: ResultAuxiliaryData {
    public let pulseMasks: [[Float]]
    public let respMasks: [[Float]]
    
    public init(pulseMasks: [[Float]], respMasks: [[Float]]) {
        self.pulseMasks = pulseMasks
        self.respMasks = respMasks
    }
}