import Foundation
import CoreGraphics
import VitalLensCore

public actor BufferManager {
    public struct ActiveBufferROI: Sendable {
        public let id: String
        public let roi: CGRect
    }
    
    private var bufferPlanner: BufferPlanner?
    private var buffers: [String: FrameBuffer] = [:]
    private var state: (any InferenceState)?
    
    public init() {}
    
    public func initialize(config: ModelConfig, constraints: BatchConstraints) {
        let rustConfig = BufferConfig(
            minNoState: UInt32(constraints.minToSend(hasState: false)),
            minWithState: UInt32(constraints.minToSend(hasState: true)),
            streamMax: UInt32(constraints.maxToSend(mode: .stream)),
            fileMax: UInt32(constraints.maxToSend(mode: .file)),
            overlap: UInt32(max(0, config.nInputs - 1))
        )
        self.bufferPlanner = BufferPlanner(config: rustConfig)
    }
    
    public func updateAndGetActiveROIs(targets: [CGRect], config: ModelConfig) -> [ActiveBufferROI] {
        guard let planner = bufferPlanner else { return [] }
        let now = Date().timeIntervalSince1970
        var active: [ActiveBufferROI] = []
        
        for target in targets {
            let action = planner.registerRoi(targetRoi: target.toRustRect(), timestamp: now)
            let id = action.id
            
            switch action.action {
            case .create:
                let rect = action.roi != nil ? CGRect(x: CGFloat(action.roi!.x), y: CGFloat(action.roi!.y), width: CGFloat(action.roi!.width), height: CGFloat(action.roi!.height)) : target
                let newBuffer = FrameBuffer(roi: rect, mode: .stream, config: config)
                buffers[id] = newBuffer
                active.append(ActiveBufferROI(id: id, roi: rect))
            case .keepAlive:
                if let buf = buffers[id] { active.append(ActiveBufferROI(id: id, roi: buf.roi)) }
            case .ignore:
                break
            }
        }
        return active
    }
    
    public func append(bufferId: String, unit: InferenceUnit, context: InferenceContext) {
        buffers[bufferId]?.append(unit: unit, context: context)
    }
    
    public func poll(mode: InferenceMode, flush: Bool = false) -> InferenceCommand? {
        guard let planner = bufferPlanner else { return nil }
        
        var counts: [String: UInt32] = [:]
        for (id, buf) in buffers { counts[id] = UInt32(buf.count) }
        
        let plan = planner.poll(currentCounts: counts, mode: mode, hasState: state != nil, flush: flush)
        for id in plan.buffersToDrop { buffers.removeValue(forKey: id) }
        
        return plan.command
    }

    public func execute(command: InferenceCommand) -> [(unit: InferenceUnit, context: InferenceContext)]? {
        return buffers[command.bufferId]?.execute(command: command)
    }
    
    public func updateState(_ newState: (any InferenceState)?) { self.state = newState }
    public func getState() -> (any InferenceState)? { return state }
    
    public func reset() {
        bufferPlanner?.reset()
        buffers.removeAll()
        state = nil
    }
}