import Foundation
import CoreGraphics

/// Represents a buffer of processed frame units tied to a specific Region of Interest (ROI).
///
/// This actor manages the accumulation of inference units (RGB Data or PixelBuffers) and handles
/// the temporal overlap required by the rPPG model (nInputs) to maintain context between inference calls.
public actor FrameBuffer {
    
    /// The fixed ROI used for all frames in this buffer.
    public let roi: CGRect
    
    /// The configuration for the model using this buffer.
    private let config: ModelConfig
    
    /// The buffering constraints (min/max batch sizes).
    private let constraints: BatchConstraints
    
    /// The accumulated frames and their metadata.
    private var buffer: [(unit: InferenceUnit, context: InferenceContext)] = []
    
    /// Creation timestamp used to prioritize newer buffers.
    public let createdAt: TimeInterval
    
    public init(
        roi: CGRect,
        config: ModelConfig,
        constraints: BatchConstraints,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.roi = roi
        self.config = config
        self.constraints = constraints
        self.createdAt = timestamp
    }
    
    /// Adds a processed inference unit to the buffer.
    ///
    /// - Parameters:
    ///   - unit: The data unit (RGB bytes or PixelBuffer).
    ///   - context: Metadata associated with the frame (timestamp, orientation, etc).
    public func append(unit: InferenceUnit, context: InferenceContext) {
        buffer.append((unit, context))
        
        // Overflow protection:
        // Use the strategy's max limit + safety margin (e.g. 2x)
        // Note: We currently assume 'stream' mode limits for general overflow protection 
        // to prevent OOM in long running sessions.
        let maxLimit = constraints.streamMax * 2
        
        if buffer.count > maxLimit {
            let dropCount = buffer.count - maxLimit
            // NEVER drop below nInputs, or we break LSTM continuity
            let safeDrop = min(dropCount, buffer.count - config.nInputs)
            
            if safeDrop > 0 {
                buffer.removeFirst(safeDrop)
                print("[FrameBuffer] Warning: Dropped \(safeDrop) frames due to overflow.")
            }
        }
    }
    
    /// Checks if the buffer contains enough frames to be processed.
    public func isReady(hasState: Bool, mode: InferenceMode) -> Bool {
        let threshold = constraints.threshold(mode: mode, hasState: hasState)
        
        if hasState {
            // We have state (RNN context).
            // We usually retain (nInputs - 1) frames.
            // Ready when: Total >= (Retained) + (New Threshold)
            return buffer.count >= (config.nInputs - 1 + threshold)
        } else {
            // Cold start. We need at least nInputs mathematically.
            // Plus whatever the strategy demands for a cold start batch.
            return buffer.count >= max(config.nInputs, threshold)
        }
    }
    
    /// Consumes the buffer for inference while retaining necessary context frames.
    public func consume() -> [(unit: InferenceUnit, context: InferenceContext)]? {
        if buffer.count < config.nInputs { return nil }
        
        let payload = buffer
        
        // Retain context for next batch (nInputs - 1)
        let framesToRetain = max(0, config.nInputs - 1)
        
        if framesToRetain > 0 {
            let suffix = buffer.suffix(framesToRetain)
            self.buffer = Array(suffix)
        } else {
            self.buffer = []
        }
        
        return payload
    }
    
    public func clear() {
        buffer.removeAll()
    }
}