import XCTest
import CoreGraphics
import VitalLensCore
@testable import VitalLensInference

final class FrameBufferTests: XCTestCase {
    
    // MARK: - Helpers
    
    private func createConfig(fps: Double = 30.0) -> ModelConfig {
        return ModelConfig(
            nInputs: 4, 
            inputSize: 40, 
            fpsTarget: fps, 
            roiMethod: "face", 
            supportedVitals: ["heart_rate"]
        )
    }
    
    private func makeTrackedFrame(index: Int, time: TimeInterval? = nil) -> (InferenceUnit, InferenceContext) {
        var data = Data(repeating: 0, count: 10)
        data[0] = UInt8(index % 255)
        let timestamp = time ?? Double(index)
        return (.rgbData(data), InferenceContext(timestamp: timestamp))
    }
    
    // MARK: - Lifecycle
    
    func testInitialization() {
        let config = createConfig()
        let roi = CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let buffer = FrameBuffer(id: "buf1", roi: roi, mode: .stream, config: config, timestamp: 1.0)
        
        XCTAssertEqual(buffer.id, "buf1")
        XCTAssertEqual(buffer.roi, roi)
        XCTAssertEqual(buffer.createdAt, 1.0)
        XCTAssertEqual(buffer.count, 0)
    }
    
    func testAppend_UpdatesState() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 1.0)
        let frame = makeTrackedFrame(index: 0, time: 1.5)
        
        buffer.append(unit: frame.0, context: frame.1)
        
        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.lastSeen, 1.5)
    }

    func testCapacity_ModeDifferences() {
        let streamBuf = FrameBuffer(id: "s", roi: .zero, mode: .stream, config: createConfig(fps: 30), timestamp: 0)
        let fileBuf = FrameBuffer(id: "f", roi: .zero, mode: .file, config: createConfig(fps: 30), timestamp: 0)
        
        // Fill stream buffer beyond its 30fps-based limit (max(150, 30*10) = 300)
        for i in 0..<350 { streamBuf.append(unit: makeTrackedFrame(index: i).0, context: makeTrackedFrame(index: i).1) }
        // Fill file buffer beyond stream limit but under file limit (1000)
        for i in 0..<350 { fileBuf.append(unit: makeTrackedFrame(index: i).0, context: makeTrackedFrame(index: i).1) }
        
        XCTAssertEqual(streamBuf.count, 300)
        XCTAssertEqual(fileBuf.count, 350)
    }
    
    // MARK: - Execution & Windowing
    
    func testExecute_ValidCommand() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 0)
        for i in 0..<10 { 
            let f = makeTrackedFrame(index: i)
            buffer.append(unit: f.0, context: f.1) 
        }
        
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 6, keepCount: 2)
        let payload = buffer.execute(command: cmd)
        
        XCTAssertEqual(payload?.count, 6)
        XCTAssertEqual(buffer.count, 6) // 10 - (6-2)
    }
    
    func testExecute_InsufficientFrames() {
        let buffer = FrameBuffer(id: "buf1", roi: .zero, mode: .stream, config: createConfig(), timestamp: 0)
        for i in 0..<5 {
            let f = makeTrackedFrame(index: i)
            buffer.append(unit: f.0, context: f.1)
        }
        
        let cmd = InferenceCommand(bufferId: "buf1", takeCount: 10, keepCount: 2)
        XCTAssertNil(buffer.execute(command: cmd))
    }
    
    func testExecute_MaintainsCorrectDataAndOverlap() {
        let buffer = FrameBuffer(id: "buf", roi: .zero, mode: .stream, config: createConfig(), timestamp: 0)
        for i in 0..<10 {
            let f = makeTrackedFrame(index: i)
            buffer.append(unit: f.0, context: f.1)
        }
        
        let cmd1 = InferenceCommand(bufferId: "buf", takeCount: 6, keepCount: 2)
        let payload1 = buffer.execute(command: cmd1)!
        
        // First batch: 0,1,2,3,4,5
        if case .rgbData(let d) = payload1.first?.unit { XCTAssertEqual(d[0], 0) }
        if case .rgbData(let d) = payload1.last?.unit { XCTAssertEqual(d[0], 5) }
        
        // Buffer now has 4,5,6,7,8,9
        let cmd2 = InferenceCommand(bufferId: "buf", takeCount: 4, keepCount: 0)
        let payload2 = buffer.execute(command: cmd2)!
        
        // Second batch: 4,5,6,7
        if case .rgbData(let d) = payload2.first?.unit {
            XCTAssertEqual(d[0], 4, "Should have started with overlap index")
        }
    }
    
    // MARK: - Capacity Management
    
    func testOverflow_DropsOldestFrames() {
        let buffer = FrameBuffer(id: "buf", roi: .zero, mode: .stream, config: createConfig(fps: 10), timestamp: 0)
        // Capacity for 10fps should be 150
        
        for i in 0..<200 {
            let f = makeTrackedFrame(index: i)
            buffer.append(unit: f.0, context: f.1)
        }
        
        XCTAssertEqual(buffer.count, 150)
        
        let cmd = InferenceCommand(bufferId: "buf", takeCount: 1, keepCount: 0)
        let payload = buffer.execute(command: cmd)!
        if case .rgbData(let d) = payload.first?.unit {
            XCTAssertEqual(d[0], 50, "Should have dropped first 50 frames")
        }
    }
}