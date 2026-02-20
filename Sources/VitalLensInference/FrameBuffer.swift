import Foundation
import CoreGraphics
import VitalLensCore

public final class FrameBuffer {
    public let id: String
    public let roi: CGRect
    public let mode: InferenceMode

    public let createdAt: TimeInterval
    public var lastSeen: TimeInterval

    private let config: ModelConfig
    private var buffer: [(unit: InferenceUnit, context: InferenceContext)] = []

    private let maxCapacity: Int
    
    public init(id: String, roi: CGRect, mode: InferenceMode, config: ModelConfig, timestamp: TimeInterval) {
        self.id = id
        self.roi = roi
        self.mode = mode
        self.config = config
        self.createdAt = timestamp
        self.lastSeen = timestamp
        self.maxCapacity = mode == .file ? 1000 : max(150, Int(config.fpsTarget * 10))
    }
    
    public var count: Int { buffer.count }
    
    public func append(unit: InferenceUnit, context: InferenceContext) {
        buffer.append((unit, context))
        self.lastSeen = context.timestamp
        
        if buffer.count > maxCapacity {
            let overflow = buffer.count - maxCapacity
            buffer.removeFirst(overflow)
        }
    }
    
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