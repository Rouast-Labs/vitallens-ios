import Foundation
import CoreGraphics
import VitalLensCore

/// A container that accumulates processed video frames for a specific region of interest (ROI) over time.
/// It manages an internal sliding window, automatically dropping the oldest frames when its maximum capacity is reached,
/// and executes extraction commands issued by the buffer planner.
public final class FrameBuffer {
    
    public let id: String    
    public let roi: CGRect
    public let mode: InferenceMode

    public let createdAt: TimeInterval
    public var lastSeen: TimeInterval

    private let config: ModelConfig
    private var buffer: [(unit: InferenceUnit, context: InferenceContext)] = []

    private let maxCapacity: Int
    
    /// Initializes a new FrameBuffer.
    ///
    /// - Parameters:
    ///   - id: The unique identifier for the buffer.
    ///   - roi: The initial region of interest to track.
    ///   - mode: The mode of processing (stream or file).
    ///   - config: The model configuration dictating fps targets and memory limits.
    ///   - timestamp: The timestamp of the first frame associated with this buffer.
    public init(id: String, roi: CGRect, mode: InferenceMode, config: ModelConfig, timestamp: TimeInterval) {
        self.id = id
        self.roi = roi
        self.mode = mode
        self.config = config
        self.createdAt = timestamp
        self.lastSeen = timestamp
        self.maxCapacity = mode == .file ? 1000 : max(150, Int(config.fpsTarget * 10))
    }
    
    /// The current number of frames stored in the buffer.
    public var count: Int { buffer.count }
    
    /// Appends a new processed frame to the buffer.
    /// Automatically discards the oldest frames if the internal capacity is exceeded.
    ///
    /// - Parameters:
    ///   - unit: The processed image data (e.g., RGB bytes or CVPixelBuffer).
    ///   - context: The metadata context (timestamp, orientation, etc.) associated with the frame.
    public func append(unit: InferenceUnit, context: InferenceContext) {
        buffer.append((unit, context))
        self.lastSeen = context.timestamp
        
        if buffer.count > maxCapacity {
            let overflow = buffer.count - maxCapacity
            buffer.removeFirst(overflow)
        }
    }
    
    /// Extracts a sequence of frames based on an inference command and adjusts the internal sliding window.
    ///
    /// - Parameter command: The command specifying how many frames to take and how many to keep for overlapping windows.
    /// - Returns: An array of frame units and their contexts, or `nil` if the buffer does not have enough frames to satisfy the take count.
    public func execute(command: InferenceCommand) -> [(unit: InferenceUnit, context: InferenceContext)]? {
        let take = Int(command.takeCount)
        let keep = Int(command.keepCount)
        
        guard take > 0, buffer.count >= take else { return nil }
        
        let payload = Array(buffer.prefix(take))
        let elementsToRemove = max(0, take - keep)
        buffer.removeFirst(elementsToRemove)
        
        return payload
    }
}