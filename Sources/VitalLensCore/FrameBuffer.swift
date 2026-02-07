import Foundation
import CoreGraphics

/// Represents a buffer of processed frames tied to a specific Region of Interest (ROI).
///
/// This actor manages the accumulation of raw RGB video frames and handles the
/// temporal overlap required by the rPPG model to maintain context between API calls.
public actor FrameBuffer {
    
    // MARK: - Properties
    
    /// The fixed ROI used for all frames in this buffer.
    public let roi: CGRect
    
    /// The configuration for the model using this buffer.
    private let config: ModelConfig
    
    /// The accumulated raw RGB data as a sequence of flattened frames.
    private var data: Data
    
    /// The number of full frames currently in the buffer.
    private var frameCount: Int = 0
    
    /// The size of a single processed frame in bytes.
    private let frameSizeBytes: Int
    
    /// Creation timestamp used to prioritize newer buffers.
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
    /// - Parameter frameData: Raw RGB bytes of a single frame. Must match the expected input size.
    public func append(frameData: Data) {
        guard frameData.count == frameSizeBytes else {
            print("FrameBuffer Warning: Dropped frame due to size mismatch. Expected \(frameSizeBytes), got \(frameData.count)")
            return
        }
        
        data.append(frameData)
        frameCount += 1
        
        // Prevent unbounded memory growth if the buffer is not being consumed
        if frameCount > 900 {
            let dropCount = frameCount - 900
            let dropBytes = dropCount * frameSizeBytes
            data.removeFirst(dropBytes)
            frameCount = 900
        }
    }
    
    /// Checks if the buffer contains enough frames to be sent to the API.
    ///
    /// - Parameter hasState: `true` if the client holds a valid RNN state from a previous request.
    /// - Returns: `true` if the buffer is ready for transmission.
    public func isReady(hasState: Bool) -> Bool {
        // If state exists, we only need nInputs frames to continue.
        // If no state exists, we need a larger batch (16 frames) to initialize the sequence.
        let threshold = hasState ? config.nInputs : 16
        return frameCount >= threshold
    }
    
    /// Consumes the buffer for API transmission while retaining necessary context frames.
    ///
    /// The rPPG model requires overlap (the last `n_inputs - 1` frames) to maintain continuity
    /// in the recurrent layers. This method extracts the full payload but leaves the overlap frames
    /// in the buffer for the next batch.
    ///
    /// - Returns: A `Data` object containing the frames to send, or `nil` if the buffer is not ready.
    public func consume() -> Data? {
        if frameCount < config.nInputs { return nil }
        
        let payload = data
        
        // Retain the last (n_inputs - 1) frames for temporal context
        let framesToRetain = max(0, config.nInputs - 1)
        
        if framesToRetain > 0 && frameCount >= framesToRetain {
            let bytesToRetain = framesToRetain * frameSizeBytes
            let retainedData = data.suffix(bytesToRetain)
            
            self.data = Data(retainedData)
            self.frameCount = framesToRetain
        } else {
            self.data = Data()
            self.frameCount = 0
        }
        
        return payload
    }
    
    /// Clears all data from the buffer.
    public func clear() {
        data.removeAll()
        frameCount = 0
    }
}