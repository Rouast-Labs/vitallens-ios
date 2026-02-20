import XCTest
import CoreGraphics
import VitalLensCore
@testable import VitalLensInference

final class FrameBufferTests: XCTestCase {
    
    // MARK: - Helpers
    
    private func createConfig() -> ModelConfig {
        return ModelConfig(
            nInputs: 4, 
            inputSize: 40, 
            fpsTarget: 30.0, 
            roiMethod: "face", 
            supportedVitals: ["heart_rate"]
        )
    }
    
    private func createDummyUnit() -> InferenceUnit {
        return .rgbData(Data([0, 1, 2]))
    }
    
    private func createDummyContext(time: TimeInterval) -> InferenceContext {
        return InferenceContext(timestamp: time)
    }
    
    // MARK: - Tests
    
    func testInitialization() {
        let config = createConfig()
        let roi = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        
        let buffer = FrameBuffer(id: "buf1", roi: roi, mode: .stream, config: config, timestamp: 1.0)
        
        XCTAssertEqual(buffer.id, "buf1")
        XCTAssertEqual(buffer.roi, roi)
        XCTAssertEqual(buffer.mode, .stream)
        XCTAssertEqual(buffer.createdAt, 1.0)
        XCTAssertEqual(buffer.lastSeen, 1.0)
        XCTAssertEqual(buffer.count, 0)
    }
    
    func testAppend_IncreasesCountAndUpdateLastSeen() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 1.5))
        
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.lastSeen, 1.5)
        
        buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 2.0))
        
        XCTAssertEqual(buffer.count, 2)
        XCTAssertEqual(buffer.lastSeen, 2.0)
        XCTAssertEqual(buffer.createdAt, 1.0, "createdAt should remain unchanged")
    }
    
    func testExecute_ValidCommand() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        for i in 0..<10 {
            buffer.append(unit: createDummyUnit(), context: createDummyContext(time: Double(i)))
        }
        
        // take 6, keep 2 -> remove 4. Remaining: 6.
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 6, keepCount: 2)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.count, 6)
        XCTAssertEqual(buffer.count, 6)
    }
    
    func testExecute_InsufficientFrames() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        for _ in 0..<5 {
            buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        }
        
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 10, keepCount: 2)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertNil(payload, "Should return nil if buffer lacks enough frames to fulfill the takeCount")
        XCTAssertEqual(buffer.count, 5, "Buffer count should remain untouched")
    }
    
    func testExecute_ZeroTake() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 0, keepCount: 0)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertNil(payload, "Should return nil for takeCount == 0")
        XCTAssertEqual(buffer.count, 1)
    }
    
    func testExecute_KeepGreaterThanTake() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        for _ in 0..<5 {
            buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        }
        
        // take 3, keep 5 -> remove max(0, 3-5) = 0. Remaining: 5.
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 3, keepCount: 5)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.count, 3)
        XCTAssertEqual(buffer.count, 5, "Should safely remove 0 frames if keep > take")
    }
    
    func testExecute_KeepEqualsTake() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        for _ in 0..<5 {
            buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        }
        
        // take 4, keep 4 -> remove 0. Remaining: 5.
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 4, keepCount: 4)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.count, 4)
        XCTAssertEqual(buffer.count, 5)
    }
    
    func testExecute_KeepZero() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        
        for _ in 0..<5 {
            buffer.append(unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        }
        
        // take 5, keep 0 -> remove 5. Remaining: 0.
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 5, keepCount: 0)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.count, 5)
        XCTAssertEqual(buffer.count, 0)
    }

    // Helper from your old tests to track specific frames
    private func makeTrackedFrame(index: Int) -> (InferenceUnit, InferenceContext) {
        var data = Data(repeating: 0, count: 10)
        data[0] = UInt8(index % 255) // Store index in first byte
        return (.rgbData(data), createDummyContext(time: Double(index)))
    }

    // MARK: - Restored Exhaustive Tests
    
    func testExecute_MaintainsCorrectDataAndOverlap() {
        let buffer = FrameBuffer(id: "buf", roi: .zero, mode: .stream, config: createConfig(), timestamp: 0)
        
        // Fill 10 frames (indices 0...9)
        for i in 0..<10 {
            let (unit, ctx) = makeTrackedFrame(index: i)
            buffer.append(unit: unit, context: ctx)
        }
        
        // Execute: Take 6, Keep 2. (Removes first 4). 
        // Payload should be [0, 1, 2, 3, 4, 5]
        // Remaining in buffer should be [4, 5, 6, 7, 8, 9]
        let cmd1 = InferenceCommand(bufferId: "buf", takeCount: 6, keepCount: 2)
        guard let payload1 = buffer.execute(command: cmd1) else {
            XCTFail("Should have consumed"); return
        }
        
        // Verify Payload 1
        XCTAssertEqual(payload1.count, 6)
        if case .rgbData(let d) = payload1.first?.unit { XCTAssertEqual(d[0], 0) }
        if case .rgbData(let d) = payload1.last?.unit { XCTAssertEqual(d[0], 5) }
        
        // Verify Buffer Retained Overlap accurately
        XCTAssertEqual(buffer.count, 6)
        
        // Add 2 new frames (10, 11) -> Buffer is now [4, 5, 6, 7, 8, 9, 10, 11]
        buffer.append(unit: makeTrackedFrame(index: 10).0, context: createDummyContext(time: 10))
        buffer.append(unit: makeTrackedFrame(index: 11).0, context: createDummyContext(time: 11))
        
        // Execute: Take 4, Keep 1. (Removes first 3). 
        // Payload should be [4, 5, 6, 7]
        let cmd2 = InferenceCommand(bufferId: "buf", takeCount: 4, keepCount: 1)
        guard let payload2 = buffer.execute(command: cmd2) else {
            XCTFail("Should have consumed"); return
        }
        
        // Verify Payload 2 starts exactly at the overlap boundary
        XCTAssertEqual(payload2.count, 4)
        if case .rgbData(let d) = payload2.first?.unit {
            XCTAssertEqual(d[0], 4, "Buffer did not maintain correct overlap context")
        }
        if case .rgbData(let d) = payload2.last?.unit {
            XCTAssertEqual(d[0], 7)
        }
    }
    
    func testOverflowProtection() {
        let buffer = FrameBuffer(id: "buf", roi: .zero, mode: .stream, config: createConfig(), timestamp: 0)
        
        // Append 500 frames (default stream maxCapacity is ~300)
        for i in 0..<500 {
            let (unit, ctx) = makeTrackedFrame(index: i)
            buffer.append(unit: unit, context: ctx)
        }
        
        // It should cap gracefully without crashing
        XCTAssertLessThanOrEqual(buffer.count, 350, "Buffer failed to drop old frames")
        
        // Ensure it kept the NEWEST frames, not the oldest
        let cmd = InferenceCommand(bufferId: "buf", takeCount: UInt32(buffer.count), keepCount: 0)
        let payload = buffer.execute(command: cmd)!
        
        if case .rgbData(let d) = payload.last?.unit {
            // The last appended index was 499. 499 % 255 = 244.
            XCTAssertEqual(d[0], 244, "Buffer should have retained the most recent frames")
        }
    }
}