import XCTest
@testable import VitalLensCore

final class FrameBufferTests: XCTestCase {
    
    // Config: 40x40 input, requires 4 frames of state context
    let config = ModelConfig(
        nInputs: 4,
        inputSize: 40,
        fpsTarget: 30,
        roiMethod: "face",
        supportedVitals: ["heart_rate"]
    )
    
    func makeFrameData(val: UInt8) -> Data {
        let size = 40 * 40 * 3
        return Data(repeating: val, count: size)
    }
    
    func testInitialization() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        // FIX: Call isReady as a function with hasState: false
        let ready = await buffer.isReady(hasState: false)
        XCTAssertFalse(ready, "Buffer should not be ready initially")
    }
    
    func testAppendAndReadyLogic() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        
        // 1. Initial State (No external state): Needs 16 frames
        for _ in 0..<15 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        let readyNoState = await buffer.isReady(hasState: false)
        XCTAssertFalse(readyNoState, "Should wait for 16 frames when no state exists")
        
        // Even if we claimed to have state, 15 frames > 4 (nInputs), so it WOULD be ready if state existed.
        let readyWithState = await buffer.isReady(hasState: true)
        XCTAssertTrue(readyWithState, "Should be ready with 15 frames if we had state (15 > 4)")
        
        // Add 16th frame
        await buffer.append(frameData: makeFrameData(val: 1))
        
        let readyAfter = await buffer.isReady(hasState: false)
        XCTAssertTrue(readyAfter, "Should be ready at 16 frames (Stateless threshold)")
    }
    
    func testConsumeMaintainsOverlap() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        let frameSize = 40 * 40 * 3
        
        // Fill 16 frames
        for i in 1...16 {
            await buffer.append(frameData: makeFrameData(val: UInt8(i)))
        }
        
        // Consume (Simulating a successful stateless request)
        // Note: In the real app, BufferManager checks isReady before calling consume.
        guard let payload1 = await buffer.consume() else {
            XCTFail(); return
        }
        XCTAssertEqual(payload1.count, 16 * frameSize)
        
        // Now simulate the Application Loop:
        // 1. Buffer retained 3 frames [14, 15, 16].
        // 2. We received State from the API (simulated by passing hasState: true).
        
        // Add 1 new frame (17)
        await buffer.append(frameData: makeFrameData(val: 17))
        
        // Check Ready with State
        let readyStateful = await buffer.isReady(hasState: true)
        XCTAssertTrue(readyStateful, "Should be ready immediately because we have state and 4 frames (3 retained + 1 new)")
        
        // Check Ready WITHOUT State (e.g. if API call failed)
        let readyStateless = await buffer.isReady(hasState: false)
        XCTAssertFalse(readyStateless, "Should NOT be ready if state was lost/failed (needs 16 frames again)")
        
        // Consume second batch
        guard let payload2 = await buffer.consume() else {
            XCTFail(); return
        }
        XCTAssertEqual(payload2.count, 4 * frameSize)
        XCTAssertEqual(payload2.first!, 14)
    }
    
    func testClear() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        
        for _ in 0..<16 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        // FIX: Call isReady as a function
        let readyBefore = await buffer.isReady(hasState: false)
        XCTAssertTrue(readyBefore)
        
        await buffer.clear()
        
        // FIX: Call isReady as a function
        let readyAfter = await buffer.isReady(hasState: false)
        XCTAssertFalse(readyAfter)
        
        // Verify behavior after clear
        for _ in 0..<4 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        // If we don't have state, 4 frames shouldn't be enough
        let readyStateless = await buffer.isReady(hasState: false)
        XCTAssertFalse(readyStateless)
        
        // If we DO have state, 4 frames should be enough
        let readyStateful = await buffer.isReady(hasState: true)
        XCTAssertTrue(readyStateful)
    }
    
    func testOverflowProtection() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        let frameSize = 40 * 40 * 3
        
        for _ in 0..<1000 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        // consume() internally checks buffer size >= nInputs, does not strictly require isReady check if forced,
        // but let's check it anyway.
        let ready = await buffer.isReady(hasState: false)
        XCTAssertTrue(ready)
        
        guard let payload = await buffer.consume() else { return }
        
        let expectedSize = 900 * frameSize
        XCTAssertEqual(payload.count, expectedSize)
    }
}