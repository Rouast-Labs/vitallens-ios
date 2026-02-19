import Foundation
import CoreGraphics

/// Represents a buffer of processed frame units tied to a specific Region of Interest (ROI).
///
/// This actor manages the accumulation of inference units (RGB Data or PixelBuffers) and handles
/// the temporal overlap required by the rPPG model (nInputs) to maintain context between inference calls.
public actor FrameBuffer {
    
    /// The fixed ROI used for all frames in this buffer.
    public let roi: CGRect
    
    /// The mode in which the buffer is being used.
    public let mode: InferenceMode

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
        mode: InferenceMode,
        config: ModelConfig,
        constraints: BatchConstraints,
        timestamp: TimeInterval = Date().timeIntervalSince1970
    ) {
        self.roi = roi
        self.mode = mode
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
        
        let maxLimit = constraints.maxToSend(mode: self.mode)
        
        if buffer.count > maxLimit {
            let dropCount = buffer.count - maxLimit
            let safeDrop = min(dropCount, buffer.count - config.nInputs)
            
            if safeDrop > 0 {
                buffer.removeFirst(safeDrop)
            }
        }
    }
    
    /// Checks if the buffer contains enough frames to be processed.
    public func isReady(hasState: Bool) -> Bool {
        let threshold = constraints.minToSend(hasState: hasState)
        return buffer.count >= threshold
    }

    /// Checks if the buffer contains enough frames for optimal processing.
    public func isOptimal(hasState: Bool, mode: InferenceMode) -> Bool {
        let threshold = constraints.optimalToSend(mode: mode, hasState: hasState)
        return buffer.count >= threshold
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