import Foundation
import CoreGraphics
import VitalLensCore

public final class FrameBuffer {
    public let roi: CGRect
    public let mode: InferenceMode
    private let config: ModelConfig
    private var buffer: [(unit: InferenceUnit, context: InferenceContext)] = []
    
    public init(roi: CGRect, mode: InferenceMode, config: ModelConfig) {
        self.roi = roi
        self.mode = mode
        self.config = config
    }
    
    public var count: Int { buffer.count }
    
    public func append(unit: InferenceUnit, context: InferenceContext) {
        buffer.append((unit, context))
    }
    
    public func execute(command: InferenceCommand) -> [(unit: InferenceUnit, context: InferenceContext)]? {
        let take = Int(command.takeCount)
        let keep = Int(command.keepCount)
        
        // Prevent empty takes from crashing
        guard take > 0, buffer.count >= take else { return nil }
        
        let payload = Array(buffer.prefix(take))
        
        // Safety clamp: Never try to remove a negative amount of elements
        let elementsToRemove = max(0, take - keep)
        buffer.removeFirst(elementsToRemove)
        
        return payload
    }
}