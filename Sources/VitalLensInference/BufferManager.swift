import Foundation
import CoreGraphics
import VitalLensCore

/// Information about a currently active buffer.
public struct ManagedBufferInfo: Sendable {
    public let id: String
    public let roi: CGRect
}

/// An actor responsible for managing video frame buffers and coordinating with the core buffer planner.
/// It handles the lifecycles of multiple overlapping regions of interest, determining when frames
/// should be accumulated, dropped, or sent for inference.
public actor BufferManager {
    
    private var bufferPlanner: BufferPlanner?
    private var buffers: [String: FrameBuffer] = [:]
    private var state: (any InferenceState)?
    
    private var currentTimestamp: TimeInterval = 0.0
    
    /// Initializes a new BufferManager.
    public init() {}

    /// Initializes the underlying buffer planner with the provided configuration.
    ///
    /// - Parameter bufferConfig: The configuration defining buffer capacities and overlap logic.
    public func initialize(bufferConfig: BufferConfig) {
        self.bufferPlanner = BufferPlanner(config: bufferConfig)
    }
    
    private func getActiveMetadata() -> [BufferMetadata] {
        return buffers.values.map { buf in
            BufferMetadata(
                id: buf.id,
                roi: buf.roi.toRustRect(),
                count: UInt32(buf.count),
                createdAt: buf.createdAt,
                lastSeen: buf.lastSeen
            )
        }
    }
    
    /// Evaluates a newly detected target against the active buffers to decide whether to create 
    /// a new tracking buffer, keep an existing one alive, or ignore the target.
    ///
    /// - Parameters:
    ///   - target: The detected face bounding box or region of interest.
    ///   - timestamp: The timestamp of the current frame.
    ///   - config: The model configuration.
    public func registerTarget(_ target: CGRect?, timestamp: TimeInterval, config: ModelConfig) {
        guard let planner = bufferPlanner, let target = target else { return }
        self.currentTimestamp = max(self.currentTimestamp, timestamp)
        
        let action = planner.evaluateTarget(targetRoi: target.toRustRect(), timestamp: timestamp, activeBuffers: getActiveMetadata())
        
        switch action.action {
        case .create:
            let newId = UUID().uuidString
            let rect = action.roi != nil ? CGRect(x: CGFloat(action.roi!.x), y: CGFloat(action.roi!.y), width: CGFloat(action.roi!.width), height: CGFloat(action.roi!.height)) : target
            let newBuffer = FrameBuffer(id: newId, roi: rect, mode: .stream, config: config, timestamp: timestamp)
            buffers[newId] = newBuffer
            
        case .keepAlive:
            if let matchedId = action.matchedId, let buf = buffers[matchedId] {
                buf.lastSeen = timestamp
            }
            
        case .ignore:
            break
        }
    }
    
    /// Retrieves a snapshot of all currently active buffers.
    ///
    /// - Returns: An array of `ManagedBufferInfo` containing buffer IDs and their respective ROIs.
    public func getAllBuffers() -> [ManagedBufferInfo] {
        return buffers.map { ManagedBufferInfo(id: $0.key, roi: $0.value.roi) }
    }
    
    /// Appends a new processed frame unit to the specified buffer.
    ///
    /// - Parameters:
    ///   - bufferId: The unique identifier of the target buffer.
    ///   - unit: The processed image data (e.g., RGB bytes or CVPixelBuffer).
    ///   - context: The metadata context (timestamp, orientation, etc.) associated with the frame.
    public func append(bufferId: String, unit: InferenceUnit, context: InferenceContext) {
        self.currentTimestamp = max(self.currentTimestamp, context.timestamp)
        buffers[bufferId]?.append(unit: unit, context: context)
    }
    
    /// Polls the planner to check if any buffer has accumulated enough frames to trigger inference.
    /// Also drops stale buffers that have not received frames recently.
    ///
    /// - Parameters:
    ///   - mode: The current inference mode (stream or file).
    ///   - flush: If true, forces the planner to yield a command even if the buffer is not completely full.
    /// - Returns: An `InferenceCommand` if a buffer is ready, or `nil` if more frames are needed.
    public func poll(mode: InferenceMode, flush: Bool = false) -> InferenceCommand? {
        guard let planner = bufferPlanner else { return nil }
        
        let plan = planner.poll(activeBuffers: getActiveMetadata(), currentTime: self.currentTimestamp, mode: mode, hasState: state != nil, flush: flush)
        
        for id in plan.buffersToDrop {
            buffers.removeValue(forKey: id)
        }
        
        return plan.command
    }

    /// Executes an inference command on a specific buffer, extracting the requested sequence of frames.
    ///
    /// - Parameter command: The command specifying the buffer ID and the counts of frames to take and keep.
    /// - Returns: An array of frame units and contexts, or `nil` if the buffer doesn't exist or lacks enough frames.
    public func execute(command: InferenceCommand) -> [(unit: InferenceUnit, context: InferenceContext)]? {
        return buffers[command.bufferId]?.execute(command: command)
    }
    
    /// Updates the global inference state.
    ///
    /// - Parameter newState: The recurrent state returned from the latest inference pass.
    public func updateState(_ newState: (any InferenceState)?) { self.state = newState }
    
    /// Retrieves the current global inference state.
    ///
    /// - Returns: The active state, or `nil` if none exists.
    public func getState() -> (any InferenceState)? { return state }
    
    /// Clears all active buffers, resets the internal timestamp, and nullifies the current state.
    public func reset() {
        buffers.removeAll()
        state = nil
        currentTimestamp = 0.0
    }
}