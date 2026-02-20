import XCTest
import CoreGraphics
import VitalLensCore
@testable import VitalLensInference

final class BufferManagerTests: XCTestCase {
    
    struct MockState: InferenceState, Equatable {
        let id: String
    }
    
    private func createConfig() -> ModelConfig {
        return ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30.0, roiMethod: "face", supportedVitals: ["heart_rate"])
    }
    
    private func createConstraints() -> BatchConstraints {
        return BatchConstraints(minNoState: 10, minWithState: 4, streamMax: 30, fileMax: 100)
    }
    
    private func createDummyUnit() -> InferenceUnit {
        return .rgbData(Data(repeating: 0, count: 10))
    }
    
    private func createDummyContext(time: TimeInterval) -> InferenceContext {
        return InferenceContext(timestamp: time)
    }
    
    func testInitialize_SetsUpPlanner() async {
        let manager = BufferManager()
        await manager.initialize(config: createConfig(), constraints: createConstraints())
        let cmd = await manager.poll(mode: .stream)
        XCTAssertNil(cmd)
    }
    
    func testRegisterTarget_NewTarget() async {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints())
        
        let rect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        await manager.registerTarget(rect, timestamp: 1.0, config: config)
        let active = await manager.getAllBuffers()
        
        XCTAssertEqual(active.count, 1)
        XCTAssertFalse(active[0].id.isEmpty)
        XCTAssertEqual(active[0].roi.minX, 0.1, accuracy: 0.001)
    }
    
    func testRegisterTarget_ExistingTarget() async throws {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints())
        
        let rect1 = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        await manager.registerTarget(rect1, timestamp: 1.0, config: config)
        let active1 = await manager.getAllBuffers()
        
        let rect2 = CGRect(x: 0.11, y: 0.11, width: 0.2, height: 0.2) // High overlap
        await manager.registerTarget(rect2, timestamp: 1.1, config: config)
        let active2 = await manager.getAllBuffers()
        
        XCTAssertEqual(active1.count, 1)
        XCTAssertEqual(active2.count, 1)
        XCTAssertEqual(active1[0].id, active2[0].id, "Should reuse the same buffer ID for overlapping ROIs")
    }
    
    func testAppend_ToExistingBuffer() async {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints())
        
        await manager.registerTarget(CGRect.zero, timestamp: 1.0, config: config)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        
        // Append 10 frames to satisfy `minNoState` requirements
        for i in 0..<10 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream, flush: true)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.takeCount, 10)
    }
    
    func testAppend_ToInvalidBuffer() async {
        let manager = BufferManager()
        await manager.initialize(config: createConfig(), constraints: createConstraints())
        
        await manager.append(bufferId: "ghost_id_123", unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        
        let cmd = await manager.poll(mode: .stream, flush: true)
        XCTAssertNil(cmd)
    }
    
    func testPoll_InsufficientFrames() async {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints()) // minNoState is 10
        
        await manager.registerTarget(CGRect.zero, timestamp: 1.0, config: config)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        
        for i in 0..<5 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream)
        XCTAssertNil(cmd)
    }
    
    func testPoll_SufficientFrames() async {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints()) // minNoState is 10
        
        await manager.registerTarget(CGRect.zero, timestamp: 1.0, config: config)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        
        for i in 0..<15 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.bufferId, id)
        XCTAssertEqual(cmd?.takeCount, 15)
    }
    
    func testPoll_DropsStaleBuffers() async throws {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints())
        
        // Create first ROI at t=1.0
        await manager.registerTarget(CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1), timestamp: 1.0, config: config)
        let id1 = await manager.getAllBuffers()[0].id
        
        // Create second ROI at t=10.0 (Pushing current logical time to 10.0, marking id1 as stale)
        await manager.registerTarget(CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), timestamp: 10.0, config: config)
        let active = await manager.getAllBuffers()
        let id2 = active.first { $0.id != id1 }!.id
        
        // Populate id2
        for i in 0..<15 {
            await manager.append(bufferId: id2, unit: createDummyUnit(), context: createDummyContext(time: 10.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream)
        XCTAssertEqual(cmd?.bufferId, id2)
        
        let flushCmd = InferenceCommand(bufferId: id1, takeCount: 1, keepCount: 0)
        let executed = await manager.execute(command: flushCmd)
        XCTAssertNil(executed, "Buffer id1 should have been dropped")
    }
    
    func testExecute_ValidCommand() async {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints())
        
        await manager.registerTarget(CGRect.zero, timestamp: 1.0, config: config)
        let id = await manager.getAllBuffers()[0].id
        
        for i in 0..<12 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = InferenceCommand(bufferId: id, takeCount: 10, keepCount: 3)
        let payload = await manager.execute(command: cmd)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.count, 10)
        
        let cmd2 = InferenceCommand(bufferId: id, takeCount: 5, keepCount: 0)
        let payload2 = await manager.execute(command: cmd2)
        XCTAssertEqual(payload2?.count, 5, "Buffer should have exactly 5 elements left")
    }
    
    func testReset_ClearsEverything() async {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(config: config, constraints: createConstraints())
        
        await manager.registerTarget(CGRect.zero, timestamp: 1.0, config: config)
        let id = await manager.getAllBuffers()[0].id
        await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        await manager.updateState(MockState(id: "test_state"))
        
        await manager.reset()
        
        let state = await manager.getState()
        XCTAssertNil(state)
        
        let cmd = await manager.poll(mode: .stream, flush: true)
        XCTAssertNil(cmd)
    }
}