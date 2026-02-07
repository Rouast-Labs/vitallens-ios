import Foundation

/// Defines an abstract backend for estimating vital signs.
public protocol InferenceStrategy: Sendable {
    
    /// Resolves the model configuration (input size, FPS, etc.) required by this strategy.
    func resolveConfig() async throws -> ModelConfig
    
    /// Processes a batch of raw video frames and returns the estimated time-series signals.
    func process(frames: Data, state: [Float]?, meta: [String: String]) async throws -> VitalLensResult
}