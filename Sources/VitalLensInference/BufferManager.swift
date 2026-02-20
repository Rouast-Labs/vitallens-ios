import Foundation
import CoreGraphics
import VitalLensCore

/// Information about a currently active buffer.
public struct ManagedBufferInfo: Sendable {
    public let id: String
    public let roi: CGRect
}

public actor BufferManager {
    
    private var bufferPlanner: BufferPlanner?
    private var buffers: [String: FrameBuffer] = [:]
    private var state: (any InferenceState)?
    
    private var currentTimestamp: TimeInterval = 0.0
    
    public init() {}

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
    
    public func getAllBuffers() -> [ManagedBufferInfo] {
        return buffers.map { ManagedBufferInfo(id: $0.key, roi: $0.value.roi) }
    }
    
    public func append(bufferId: String, unit: InferenceUnit, context: InferenceContext) {
        self.currentTimestamp = max(self.currentTimestamp, context.timestamp)
        buffers[bufferId]?.append(unit: unit, context: context)
    }
    
    public func poll(mode: InferenceMode, flush: Bool = false) -> InferenceCommand? {
        guard let planner = bufferPlanner else { return nil }
        
        let plan = planner.poll(activeBuffers: getActiveMetadata(), currentTime: self.currentTimestamp, mode: mode, hasState: state != nil, flush: flush)
        
        for id in plan.buffersToDrop {
            buffers.removeValue(forKey: id)
        }
        
        return plan.command
    }

    public func execute(command: InferenceCommand) -> [(unit: InferenceUnit, context: InferenceContext)]? {
        return buffers[command.bufferId]?.execute(command: command)
    }
    
    public func updateState(_ newState: (any InferenceState)?) { self.state = newState }
    public func getState() -> (any InferenceState)? { return state }
    
    public func reset() {
        buffers.removeAll()
        state = nil
        currentTimestamp = 0.0
    }
}