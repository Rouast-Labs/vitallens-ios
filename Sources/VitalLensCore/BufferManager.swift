import Foundation
import CoreGraphics

/// Manages multiple `FrameBuffer` instances to handle changes in Region of Interest (ROI) and face movement.
public actor BufferManager {
    
    // MARK: - Types
    
    /// Represents an active ROI that requires processing for a specific buffer ID.
    public struct ActiveBufferROI: Sendable {
        /// The unique identifier of the target buffer.
        public let id: String
        /// The normalized region of interest (0.0 - 1.0) to crop.
        public let roi: CGRect
        
        public init(id: String, roi: CGRect) {
            self.id = id
            self.roi = roi
        }
    }
    
    private struct ManagedBuffer {
        let id: String
        let buffer: FrameBuffer
        /// The timestamp of the last time this buffer was matched to an ROI.
        var lastUsed: TimeInterval
    }
    
    // MARK: - Properties
    
    private var buffers: [String: ManagedBuffer] = [:]
    
    private var state: (any InferenceState)?

    public init() {}
    
    // MARK: - Core Logic
    
    /// Evaluates incoming target ROIs against existing buffers.
    ///
    /// - Parameters:
    ///   - targets: List of desired ROIs for the current frame.
    ///   - constraints: Batch limits for new buffers.
    ///   - config: Model configuration.
    /// - Returns: List of active buffer IDs and the ROIs they should use.
    public func updateAndGetActiveROIs(
        targets: [CGRect],
        constraints: BatchConstraints,
        config: ModelConfig
    ) -> [ActiveBufferROI] {
        let now = Date().timeIntervalSince1970
        var active: [ActiveBufferROI] = []
        
        // Threshold for "Same Buffer". 0.9 means 90% overlap required.
        // If overlap drops below this (due to face drift or rotation), we create a new buffer.
        let iouThreshold: CGFloat = 0.90
        
        for target in targets {
            // Find the best matching existing buffer
            var bestMatchID: String?
            var bestIoU: CGFloat = -1.0
            
            for (id, managed) in buffers {
                let overlap = ROICalculator.computeIoU(target, managed.buffer.roi)
                if overlap > bestIoU {
                    bestIoU = overlap
                    bestMatchID = id
                }
            }
            
            if let matchID = bestMatchID, bestIoU >= iouThreshold {
                // Keep using existing buffer
                buffers[matchID]?.lastUsed = now
                active.append(ActiveBufferROI(id: matchID, roi: buffers[matchID]!.buffer.roi))
            } else {
                // Create new buffer
                let newID = UUID().uuidString
                let newBuffer = FrameBuffer(roi: target, config: config, constraints: constraints, timestamp: now)
                buffers[newID] = ManagedBuffer(id: newID, buffer: newBuffer, lastUsed: now)
                active.append(ActiveBufferROI(id: newID, roi: target))
            }
        }
        
        // Cleanup old buffers (unused for > 5 seconds)
        // This handles cases where a face leaves the frame or device rotates.
        for (id, managed) in buffers {
            if now - managed.lastUsed > 5.0 {
                buffers.removeValue(forKey: id)
            }
        }
        
        return active
    }
    
    /// Appends a processed inference unit to a specific buffer.
    public func append(bufferId: String, unit: InferenceUnit, context: InferenceContext) async {
        guard let wrapper = buffers[bufferId] else { return }
        await wrapper.buffer.append(unit: unit, context: context)
    }
    
    public func getReadyBuffer(mode: InferenceMode) async -> FrameBuffer? {
        let hasState = (state != nil)
        var readyBuffers: [FrameBuffer] = []
        
        for wrapper in buffers.values {
            if await wrapper.buffer.isReady(hasState: hasState, mode: mode) {
                readyBuffers.append(wrapper.buffer)
            }
        }
        
        // Prioritize newest buffer (most relevant ROI)
        return readyBuffers.sorted { $0.createdAt > $1.createdAt }.first
    }
    
    // MARK: - State Management
    
    /// Updates the cached state from the API response.
    public func updateState(_ newState: (any InferenceState)?) {
        self.state = newState
    }
    
    /// Retrieves the current cached state.
    public func getState() -> (any InferenceState)? {
        return state
    }
    
    /// Clears all buffers and state.
    public func reset() {
        buffers.removeAll()
        state = nil
    }
}