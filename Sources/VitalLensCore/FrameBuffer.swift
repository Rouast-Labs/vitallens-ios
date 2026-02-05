import Foundation
import CoreGraphics

/// Represents a buffer of processed frames tied to a specific Region of Interest (ROI).
/// It handles the temporal overlap required by the rPPG model (retaining context frames).
public actor FrameBuffer {
    
    // MARK: - Properties
    
    /// The fixed ROI used for all frames in this buffer.
    /// If the face moves out of this ROI, a new buffer must be created.
    public let roi: CGRect
    
    /// The configuration for the model using this buffer.
    private let config: ModelConfig
    
    /// The accumulated raw RGB data.
    /// Format: A sequence of flattened frames.
    private var data: Data
    
    /// The number of full frames currently in `data`.
    private var frameCount: Int = 0
    
    /// The size of a single processed frame in bytes.
    private let frameSizeBytes: Int
    
    /// Creation timestamp to prioritize newer buffers.
    public let createdAt: TimeInterval
    
    // MARK: - Initialization
    
    public init(roi: CGRect, config: ModelConfig, timestamp: TimeInterval = Date().timeIntervalSince1970) {
        self.roi = roi
        self.config = config
        self.createdAt = timestamp
        self.data = Data()
        self.frameSizeBytes = config.inputSize * config.inputSize * 3
    }
    
    // MARK: - Public API
    
    /// Adds processed frame bytes to the buffer.
    ///
    /// - Parameter frameData: Raw RGB bytes of a single frame (must match expected size).
    public func append(frameData: Data) {
        guard frameData.count == frameSizeBytes else {
            print("FrameBuffer Warning: Dropped frame due to size mismatch. Expected \(frameSizeBytes), got \(frameData.count)")
            return
        }
        
        data.append(frameData)
        frameCount += 1
        
        // Cap buffer to prevent overflow
        if frameCount > 900 {
            let dropCount = frameCount - 900
            let dropBytes = dropCount * frameSizeBytes
            data.removeFirst(dropBytes)
            frameCount = 900
        }
    }
    
    /// Checks if the buffer is ready, given the current system state.
    /// - Parameter hasState: Whether the client currently holds a valid RNN state.
    public func isReady(hasState: Bool) -> Bool {
        // If we have state, we only need nInputs (e.g. 4) frames to continue the sequence.
        // If we DON'T have state, we need a full 16 frames to start a new sequence.
        let threshold = hasState ? config.nInputs : 16
        return frameCount >= threshold
    }
    
    /// Consumes the buffer for API transmission, ensuring temporal context is retained.
    ///
    /// - Returns: A `Data` object containing the frames to send, or `nil` if not ready.
    public func consume() -> Data? {       
        if frameCount < config.nInputs { return nil }
        
        let payload = data
        
        // --- CRITICAL OVERLAP LOGIC ---
        // We must RETAIN the last (n_inputs - 1) frames to provide context for the next batch.
        let framesToRetain = max(0, config.nInputs - 1)
        
        if framesToRetain > 0 && frameCount >= framesToRetain {
            // Calculate bytes to keep
            let bytesToRetain = framesToRetain * frameSizeBytes
            
            // Slice the last N bytes
            // Note: Data slicing allows efficient access but we need a new Data object for the buffer
            let retainedData = data.suffix(bytesToRetain)
            
            // Reset buffer with retained data
            self.data = Data(retainedData)
            self.frameCount = framesToRetain
        } else {
            // If we somehow have fewer frames than context (shouldn't happen if isReady is checked), clear all.
            self.data = Data()
            self.frameCount = 0
        }
        
        return payload
    }
    
    /// Clears the buffer completely.
    public func clear() {
        data.removeAll()
        frameCount = 0
    }
}