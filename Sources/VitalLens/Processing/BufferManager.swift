import Foundation
import CoreGraphics

/// Manages multiple `FrameBuffer` instances to handle ROI changes and face movement.
actor BufferManager {
    
    // MARK: - Types
    
    struct ActiveBufferROI: Sendable {
        let id: String
        let roi: CGRect
    }
    
    private struct ManagedBuffer {
        let id: String
        let buffer: FrameBuffer
    }
    
    // MARK: - Properties
    
    private var buffers: [String: ManagedBuffer] = [:]
    
    /// The RNN state from the API. We cache it here to inject it into whichever buffer triggers next.
    private var rnnState: [Float]?
    
    // MARK: - Core Logic
    
    /// Evaluates the current face detection against existing buffers and determines which ROIs need processing.
    ///
    /// - Parameters:
    ///   - faceRect: The normalized bounding box of the face (Top-Left origin).
    ///   - config: The model configuration.
    /// - Returns: A list of ROIs that the caller must crop/process and feed back to `append`.
    func updateAndGetActiveROIs(
        faceRect: CGRect?,
        config: ModelConfig
    ) -> [ActiveBufferROI] {
        let now = Date().timeIntervalSince1970
        
        // 1. If we have a face, check if we need a NEW buffer.
        // We need a new buffer if NO existing buffer has an ROI that sufficiently contains the current face.
        if let face = faceRect {
            
            // Calculate the "Ideal" ROI for this exact moment
            let idealROI = ROICalculator.calculateROI(
                from: face,
                method: config.roiMethod,
                frameSize: CGSize(width: 1, height: 1) // Normalized
            )
            
            // Check if any existing buffer is "good enough"
            let isCovered = buffers.values.contains { managed in
                // Logic ported from `checkFaceInROI` (vitallens.js)
                // Does the current face fit inside the buffer's FIXED ROI?
                return ROICalculator.isFace(face, sufficientlyInsideROI: managed.buffer.roi)
            }
            
            if !isCovered {
                // Face has drifted or this is the first frame. Create a NEW buffer.
                // This buffer is tied to the NEW `idealROI`.
                let id = UUID().uuidString
                let newBuffer = FrameBuffer(roi: idealROI, config: config, timestamp: now)
                buffers[id] = ManagedBuffer(id: id, buffer: newBuffer)
            }
        }
        
        // 2. Return the ROI for EVERY active buffer.
        // The StreamProcessor must process the frame for *all* of them to ensure continuity.
        // (e.g. Old buffer needs data until it flushes; New buffer needs data to start filling).
        return buffers.values.map {
            ActiveBufferROI(id: $0.id, roi: $0.buffer.roi)
        }
    }
    
    /// Adds processed data to a specific buffer.
    func append(bufferId: String, data: Data) async {
        guard let wrapper = buffers[bufferId] else { return }
        await wrapper.buffer.append(frameData: data)
        
        // Cleanup: If we have too many buffers, remove old ones that aren't the "primary" anymore?
        // For simplicity in V1: We assume `getReadyBuffer` consumes and creates natural turnover,
        // or we rely on explicit cleanup.
        // Real-world: You might want to prune buffers that haven't been "covered" by a face for X seconds.
        // TODO: Prune buffers
    }
    
    /// Retrieves the *best* buffer that is ready to send to the API.
    /// Prioritizes the most recently created buffer (the one matching the newest ROI).
    func getReadyBuffer() async -> FrameBuffer? {
        var readyBuffers: [FrameBuffer] = []
        
        for wrapper in buffers.values {
            if await wrapper.buffer.isReady {
                readyBuffers.append(wrapper.buffer)
            }
        }
        
        // Return the newest ready buffer
        return readyBuffers.sorted { $0.createdAt > $1.createdAt }.first
    }
    
    // MARK: - State Management
    
    func updateState(_ state: [Float]) {
        self.rnnState = state
    }
    
    func getState() -> [Float]? {
        return rnnState
    }
    
    func reset() {
        buffers.removeAll()
        rnnState = nil
    }
}