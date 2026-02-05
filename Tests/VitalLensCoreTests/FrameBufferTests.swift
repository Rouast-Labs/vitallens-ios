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
    
    // Helper to generate a dummy "Frame" of raw bytes
    // Size = 40 * 40 * 3 = 4800 bytes
    func makeFrameData(val: UInt8) -> Data {
        let size = 40 * 40 * 3
        return Data(repeating: val, count: size)
    }
    
    func testInitialization() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        let ready = await buffer.isReady
        XCTAssertFalse(ready, "Buffer should not be ready initially")
    }
    
    func testAppendAndReadyLogic() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        
        // VitalLens default min window is 16 frames.
        // Let's add 15 frames.
        for _ in 0..<15 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        let readyBefore = await buffer.isReady
        XCTAssertFalse(readyBefore, "Buffer should not be ready at 15 frames")
        
        // Add 16th frame
        await buffer.append(frameData: makeFrameData(val: 1))
        
        let readyAfter = await buffer.isReady
        XCTAssertTrue(readyAfter, "Buffer should be ready at 16 frames")
    }
    
    func testConsumeMaintainsOverlap() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        let frameSize = 40 * 40 * 3
        
        // 1. Fill buffer with identifiable data (1...16)
        for i in 1...16 {
            await buffer.append(frameData: makeFrameData(val: UInt8(i)))
        }
        
        // 2. Consume first batch
        guard let payload1 = await buffer.consume() else {
            XCTFail("Payload 1 should be ready")
            return
        }
        
        // Expect full payload (16 frames)
        XCTAssertEqual(payload1.count, 16 * frameSize)
        
        // 3. Check Retention logic
        // Model requires nInputs=4. We should retain (4-1) = 3 frames.
        // The buffer should now contain frames [14, 15, 16].
        
        // Add one new frame (17)
        await buffer.append(frameData: makeFrameData(val: 17))
        
        // Verify internal state implicitly via consume
        // We artificially force it to return whatever it has by checking count logic if we could,
        // but since `consume` requires `isReady` (16 frames), we can't consume yet.
        // Let's verify we need exactly 12 more frames to be ready (3 existing + 1 new + 12 = 16).
        
        for i in 18...29 {
            await buffer.append(frameData: makeFrameData(val: UInt8(i)))
        }
        
        let readyNow = await buffer.isReady
        XCTAssertTrue(readyNow, "Should be ready again after adding 13 frames (3 retained + 13 new = 16)")
        
        // 4. Consume second batch
        guard let payload2 = await buffer.consume() else {
            XCTFail("Payload 2 should be ready")
            return
        }
        
        // Verify the data content of the SECOND batch.
        // It should start with the retained frames [14, 15, 16] followed by [17...29]
        let firstByte = payload2.first!
        XCTAssertEqual(firstByte, 14, "Second batch should start with retained frame 14")
    }
    
    func testClear() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        
        for _ in 0..<16 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        XCTAssertTrue(await buffer.isReady)
        
        await buffer.clear()
        
        XCTAssertFalse(await buffer.isReady)
    }
    
    func testOverflowProtection() async {
        let buffer = FrameBuffer(roi: .zero, config: config)
        
        // Add 1000 frames (Max is 900)
        for _ in 0..<1000 {
            await buffer.append(frameData: makeFrameData(val: 1))
        }
        
        // We can't easily check private frameCount, but we can check if `consume` returns a clamped data size.
        // Actually `consume` returns `data`.
        // 900 frames * size
        guard let payload = await buffer.consume() else { return }
        
        let expectedSize = 900 * (40 * 40 * 3)
        XCTAssertEqual(payload.count, expectedSize, "Buffer should be capped at 900 frames")
    }
}