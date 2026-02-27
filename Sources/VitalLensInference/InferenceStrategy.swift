import Foundation
import CoreVideo
import ImageIO
import VitalLensCore

/// A thread-safe wrapper for `CVPixelBuffer`.
public struct SendablePixelBuffer: @unchecked Sendable {
    
    public let buffer: CVPixelBuffer
    
    /// Initializes a new thread-safe pixel buffer wrapper.
    ///
    /// - Parameter buffer: The raw `CVPixelBuffer` to wrap.
    public init(_ buffer: CVPixelBuffer) { 
        self.buffer = buffer 
    }
}

/// Represents the unit of image data to be processed during inference.
public enum InferenceUnit: Sendable {
    
    /// Pre-processed, flattened RGB bytes. Typically used for the Remote API.
    case rgbData(Data)
    
    /// A raw image buffer. Typically used for Local CoreML inference.
    case pixelBuffer(SendablePixelBuffer)
}

/// Contextual metadata associated with a specific video frame unit.
public struct InferenceContext: Sendable {
    
    /// The timestamp of the frame in seconds.
    public let timestamp: TimeInterval    
    
    /// The physical orientation of the original image.
    public let orientation: CGImagePropertyOrientation
    
    /// Indicates whether the original image is horizontally mirrored.
    public let isMirrored: Bool
    
    /// The normalized bounding box defining the region of interest within the frame.
    public let roi: CGRect
    
    /// Initializes a new context for an inference frame.
    ///
    /// - Parameters:
    ///   - timestamp: The timestamp of the frame in seconds.
    ///   - orientation: The physical orientation of the original image. Defaults to `.up`.
    ///   - isMirrored: Whether the original image is horizontally mirrored. Defaults to `false`.
    ///   - roi: The normalized region of interest. Defaults to `.zero`.
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

/// A protocol representing the recurrent internal state of an inference model.
public protocol InferenceState: Sendable {}

/// Defines an abstract backend strategy for estimating vital signs from video frames.
public protocol InferenceStrategy: Sendable {

    /// Defines the buffering limits and parameters for this specific strategy.
    var bufferConfig: VitalLensCore.BufferConfig { get async throws }
    
    /// Resolves the model configuration (e.g., input size, target FPS) required by this strategy.
    ///
    /// - Returns: The resolved `ModelConfig` detailing the preprocessing requirements.
    /// - Throws: An error if the configuration cannot be resolved.
    func resolveConfig() async throws -> ModelConfig
    
    /// Processes a window of frames and returns the estimated time-series signals.
    ///
    /// - Parameters:
    ///   - window: A list of frame units and their associated context metadata.
    ///   - state: The opaque recurrent neural network state from the previous inference pass, if any.
    ///   - mode: The execution mode dictating how data is handled (e.g., live stream or batch file).
    ///   - model: An optional model identifier to override the default selection.
    /// - Returns: A tuple containing the resulting vital signs (`VitalLensResult`) and the updated model state (`newState`).
    /// - Throws: An error if the inference process fails.
    func infer(
        window: [(InferenceUnit, InferenceContext)], 
        state: (any InferenceState)?, 
        mode: InferenceMode, 
        model: String?
    ) async throws -> (result: VitalLensResult, newState: (any InferenceState)?)
}