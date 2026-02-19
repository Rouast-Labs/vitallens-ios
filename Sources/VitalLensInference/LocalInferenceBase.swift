import Foundation
import CoreVideo
import VitalLensCore

/// A generic base strategy for running local CoreML models.
/// Consumers must subclass this to inject their specific model logic.
open class LocalInferenceBase: InferenceStrategy, @unchecked Sendable {
    
    // Config must be provided by the subclass
    public let config: ModelConfig
    
    public init(config: ModelConfig) {
        self.config = config
    }

    public var batchConstraints: BatchConstraints {
        return BatchConstraints(for: config)
    }

    public func resolveConfig() async throws -> ModelConfig {
        return config
    }

    /// Abstract method: Must be overridden by the app to run the actual CoreML prediction.
    /// - Parameters:
    ///   - frames: The prepared video frames (PixelBuffers).
    ///   - state: The opaque state from the previous frame.
    /// - Returns: A tuple of (Raw VitalLensResult, New State).
    open func predict(frames: [CVPixelBuffer], state: (any InferenceState)?) async throws -> (VitalLensResult, (any InferenceState)?) {
        fatalError("Subclasses must implement predict(frames:state:)")
    }

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