import Foundation
import CoreVideo
import VitalLensCore

/// A generic base strategy for running local CoreML models.
/// Consumers must subclass this to inject their specific model logic.
open class LocalInferenceBase: InferenceStrategy, @unchecked Sendable {
    
    /// The model configuration dictating input requirements.
    public let config: ModelConfig
    
    /// Initializes a new local inference strategy with a predefined configuration.
    ///
    /// - Parameter config: The configuration specifying input sizes, framerates, and other model parameters.
    public init(config: ModelConfig) {
        self.config = config
    }

    /// The buffer configuration dictated by the active model settings.
    public var bufferConfig: VitalLensCore.BufferConfig {
        return VitalLensCore.computeBufferConfig(config: config.toSessionConfig())
    }

    /// Returns the locally predefined model configuration.
    ///
    /// - Returns: The finalized `ModelConfig`.
    public func resolveConfig() async throws -> ModelConfig {
        return config
    }

    /// Executes the actual local CoreML prediction.
    /// Subclasses must override this method to inject their specific model execution logic.
    ///
    /// - Parameters:
    ///   - frames: An array of prepared CoreVideo pixel buffers.
    ///   - state: The opaque recurrent state from the previous inference, if any.
    /// - Returns: A tuple containing the raw `VitalLensResult` and the updated `InferenceState`.
    /// - Throws: An error if the prediction fails.
    open func predict(frames: [CVPixelBuffer], state: (any InferenceState)?) async throws -> (VitalLensResult, (any InferenceState)?) {
        fatalError("Subclasses must implement predict(frames:state:)")
    }

    /// Processes a window of frames using the local prediction logic.
    /// Ensures all incoming frames are in the expected `pixelBuffer` format before calling `predict`.
    ///
    /// - Parameters:
    ///   - window: A list of frame units and their contextual metadata.
    ///   - state: The opaque state from the previous inference, if any.
    ///   - mode: The mode of inference (stream or file).
    ///   - model: An optional model identifier (typically ignored in local inference).
    /// - Returns: A tuple containing the inference result and the updated state.
    /// - Throws: `VitalLensError` if the inputs are not pixel buffers or if prediction fails.
    public func infer(
        window: [(InferenceUnit, InferenceContext)], 
        state: (any InferenceState)?, 
        mode: InferenceMode, 
        model: String?
    ) async throws -> (result: VitalLensResult, newState: (any InferenceState)?) {
        
        let pixelBuffers = try window.map { unit, _ -> CVPixelBuffer in
            guard case .pixelBuffer(let wrapper) = unit else {
                throw VitalLensError.processingError("Local strategy requires .pixelBuffer inputs")
            }
            return wrapper.buffer
        }
        
        let (result, newState) = try await predict(frames: pixelBuffers, state: state)
        
        return (result, newState)
    }
}