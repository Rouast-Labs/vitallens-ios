import Foundation
import CoreGraphics

/// Manages multiple `FrameBuffer` instances to handle changes in Region of Interest (ROI) and face movement.
///
/// This actor ensures that when a face moves significantly (drift), a new buffer is created to track the new ROI,
/// while existing buffers continue to process data until they are flushed or pruned.
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
    }
    
    // MARK: - Properties
    
    private var buffers: [String: ManagedBuffer] = [:]
    
    /// The recurrent state (RNN) from the API, cached to be injected into the next ready buffer.
    private var rnnState: [Float]?

    public init() {}
    
    // MARK: - Core Logic
    
    /// Evaluates the current face detection against existing buffers and determines which ROIs need processing.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized bounding box of the face (Top-Left origin), or `nil` if no face is detected.
    ///   - config: The model configuration containing ROI calculation rules.
    /// - Returns: A list of `ActiveBufferROI` that the caller must process and feed back via `append`.
    public func updateAndGetActiveROIs(
        faceRect: CGRect?,
        config: ModelConfig
    ) -> [ActiveBufferROI] {
        let now = Date().timeIntervalSince1970
        
        // 1. New Buffer Creation Logic
        if let face = faceRect {
            
            // Calculate the ideal ROI for the current face position
            let idealROI = ROICalculator.calculateROI(
                from: face,
                method: config.roiMethod,
                frameSize: CGSize(width: 1, height: 1)
            )
            
            // Check if the face is sufficiently covered by any existing buffer
            let isCovered = buffers.values.contains { managed in
                return ROICalculator.isFace(face, sufficientlyInsideROI: managed.buffer.roi)
            }
            
            // If the face has drifted out of all existing ROIs, create a new buffer
            if !isCovered {
                let id = UUID().uuidString
                let newBuffer = FrameBuffer(roi: idealROI, config: config, timestamp: now)
                buffers[id] = ManagedBuffer(id: id, buffer: newBuffer)
            }
        }
        
        // 2. Return ROIs for all active buffers
        return buffers.values.map {
            ActiveBufferROI(id: $0.id, roi: $0.buffer.roi)
        }
    }
    
    /// Appends processed frame data to a specific buffer.
    ///
    /// - Parameters:
    ///   - bufferId: The UUID of the target buffer.
    ///   - data: The raw RGB bytes of the processed frame.
    public func append(bufferId: String, data: Data) async {
        guard let wrapper = buffers[bufferId] else { return }
        await wrapper.buffer.append(frameData: data)
    }
    
    /// Retrieves the most appropriate buffer that is ready for transmission.
    /// Prioritizes the most recently created buffer (i.e., the one tracking the newest ROI).
    ///
    /// - Returns: The ready `FrameBuffer`, or `nil` if no buffer meets the readiness criteria.
    public func getReadyBuffer() async -> FrameBuffer? {
        let hasState = (rnnState != nil && !rnnState!.isEmpty)
        var readyBuffers: [FrameBuffer] = []
        
        for wrapper in buffers.values {
            if await wrapper.buffer.isReady(hasState: hasState) {
                readyBuffers.append(wrapper.buffer)
            }
        }
        
        // Sort by creation time (descending) to prioritize the newest ROI
        return readyBuffers.sorted { $0.createdAt > $1.createdAt }.first
    }
    
    // MARK: - State Management
    
    /// Updates the cached RNN state from the API response.
    public func updateState(_ state: [Float]) {
        self.rnnState = state
    }
    
    /// Retrieves the current cached RNN state.
    public func getState() -> [Float]? {
        return rnnState
    }
    
    /// Clears all buffers and state.
    public func reset() {
        buffers.removeAll()
        rnnState = nil
    }
}