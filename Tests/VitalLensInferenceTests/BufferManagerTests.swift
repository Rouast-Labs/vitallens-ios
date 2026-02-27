import XCTest
import CoreGraphics
import VitalLensCore
@testable import VitalLensInference

final class BufferManagerTests: XCTestCase {
    
    struct MockState: InferenceState, Equatable {
        let id: String
    }
    
    // MARK: - Helpers & Setup
    
    private func createConfig() -> ModelConfig {
        return ModelConfig(
            nInputs: 4,
            inputSize: 40,
            fpsTarget: 30.0,
            roiMethod: "face",
            supportedVitals: ["heart_rate"]
        )
    }
    
    private func createBufferConfig() -> BufferConfig {
        return BufferConfig(minNoState: 10, minWithState: 4, streamMax: 30, fileMax: 100, overlap: 3)
    }
    
    private func createDummyUnit() -> InferenceUnit {
        return .rgbData(Data(repeating: 0, count: 10))
    }
    
    private func createDummyContext(time: TimeInterval) -> InferenceContext {
        return InferenceContext(timestamp: time)
    }
    
    private func makeInitializedManager(target: CGRect? = nil, targetTime: TimeInterval = 1.0) async -> (BufferManager, ModelConfig) {
        let manager = BufferManager()
        let config = createConfig()
        await manager.initialize(bufferConfig: createBufferConfig())
        if let rect = target {
            await manager.registerTarget(rect, timestamp: targetTime, config: config)
        }
        return (manager, config)
    }

    // MARK: - Initialization

    func testInitialize_SetsUpPlanner() async {
        let (manager, _) = await makeInitializedManager()
        let cmd = await manager.poll(mode: .stream)
        XCTAssertNil(cmd)
    }
    
    // MARK: - Target Registration
    
    func testRegisterTarget_NewTarget() async {
        let (manager, _) = await makeInitializedManager(target: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let active = await manager.getAllBuffers()
        
        XCTAssertEqual(active.count, 1)
        XCTAssertFalse(active[0].id.isEmpty)
        XCTAssertEqual(active[0].roi.minX, 0.1, accuracy: 0.001)
    }
    
    func testRegisterTarget_ExistingTarget() async throws {
        let (manager, config) = await makeInitializedManager(target: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2))
        let active1 = await manager.getAllBuffers()
        
        await manager.registerTarget(CGRect(x: 0.11, y: 0.11, width: 0.2, height: 0.2), timestamp: 1.1, config: config)
        let active2 = await manager.getAllBuffers()
        
        XCTAssertEqual(active1.count, 1)
        XCTAssertEqual(active2.count, 1)
        XCTAssertEqual(active1[0].id, active2[0].id)
    }
    
    func testRegisterTarget_MultipleDistinctTargets() async throws {
        let (manager, config) = await makeInitializedManager(target: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        await manager.registerTarget(CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), timestamp: 1.0, config: config)
        
        let active = await manager.getAllBuffers()
        XCTAssertEqual(active.count, 2)
        XCTAssertNotEqual(active[0].id, active[1].id)
    }
    
    // MARK: - Appending & Polling
    
    func testAppend_ToExistingBuffer() async {
        let (manager, _) = await makeInitializedManager(target: .zero)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        
        for i in 0..<10 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream, flush: true)
        XCTAssertNotNil(cmd)
        XCTAssertEqual(cmd?.takeCount, 10)
    }
    
    func testAppend_ToInvalidBuffer() async {
        let (manager, _) = await makeInitializedManager()
        
        await manager.append(bufferId: "ghost_id_123", unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        
        let cmd = await manager.poll(mode: .stream, flush: true)
        XCTAssertNil(cmd)
    }
    
    func testPoll_InsufficientFrames() async {
        let (manager, _) = await makeInitializedManager(target: .zero)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        
        for i in 0..<5 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream)
        XCTAssertNil(cmd)
    }
    
    func testPoll_SufficientFrames() async {
        let (manager, _) = await makeInitializedManager(target: .zero)
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
        let (manager, config) = await makeInitializedManager(target: CGRect(x: 0.1, y: 0.1, width: 0.1, height: 0.1))
        let active1 = await manager.getAllBuffers()
        let id1 = active1[0].id
        
        await manager.registerTarget(CGRect(x: 0.8, y: 0.8, width: 0.1, height: 0.1), timestamp: 10.0, config: config)
        let active2 = await manager.getAllBuffers()
        let id2 = active2.first { $0.id != id1 }!.id
        
        for i in 0..<15 {
            await manager.append(bufferId: id2, unit: createDummyUnit(), context: createDummyContext(time: 10.0 + Double(i)))
        }
        
        let cmd = await manager.poll(mode: .stream)
        XCTAssertEqual(cmd?.bufferId, id2)
        
        let flushCmd = InferenceCommand(bufferId: id1, takeCount: 1, keepCount: 0)
        let executed = await manager.execute(command: flushCmd)
        XCTAssertNil(executed)
    }
    
    // MARK: - Execution
    
    func testExecute_ValidCommand() async {
        let (manager, _) = await makeInitializedManager(target: .zero)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        
        for i in 0..<12 {
            await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0 + Double(i)))
        }
        
        let cmd = InferenceCommand(bufferId: id, takeCount: 10, keepCount: 3)
        let payload = await manager.execute(command: cmd)
        
        XCTAssertNotNil(payload)
        XCTAssertEqual(payload?.count, 10)
        
        let cmd2 = InferenceCommand(bufferId: id, takeCount: 5, keepCount: 0)
        let payload2 = await manager.execute(command: cmd2)
        XCTAssertEqual(payload2?.count, 5)
    }
    
    // MARK: - State & Lifecycle
    
    func testStateManagement() async {
        let (manager, _) = await makeInitializedManager()
        
        let initialState = await manager.getState()
        XCTAssertNil(initialState)
        
        await manager.updateState(MockState(id: "state_1"))
        let state1 = await manager.getState() as? MockState
        XCTAssertEqual(state1?.id, "state_1")
        
        await manager.updateState(MockState(id: "state_2"))
        let state2 = await manager.getState() as? MockState
        XCTAssertEqual(state2?.id, "state_2")
    }

    func testReset_ClearsEverything() async {
        let (manager, _) = await makeInitializedManager(target: .zero)
        let active = await manager.getAllBuffers()
        let id = active[0].id
        await manager.append(bufferId: id, unit: createDummyUnit(), context: createDummyContext(time: 1.0))
        await manager.updateState(MockState(id: "test_state"))
        
        await manager.reset()
        
        let finalState = await manager.getState()
        XCTAssertNil(finalState)
        
        let finalBuffers = await manager.getAllBuffers()
        XCTAssertTrue(finalBuffers.isEmpty)
        
        let cmd = await manager.poll(mode: .stream, flush: true)
        XCTAssertNil(cmd)
    }
}