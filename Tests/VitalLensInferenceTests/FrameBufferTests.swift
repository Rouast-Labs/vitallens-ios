// import XCTest
// @testable import VitalLensInference

// final class FrameBufferTests: XCTestCase {
    
//     // Config: 40x40 input, requires 4 frames of state context
//     let config = ModelConfig(
//         nInputs: 4,
//         inputSize: 40,
//         fpsTarget: 30.0,
//         roiMethod: "face",
//         supportedVitals: ["heart_rate"]
//     )
    
//     // Explicit constraints for testing
//     let constraints = BatchConstraints(
//         minNoState: 16,
//         minWithState: 4,
//         streamMax: 120,
//         fileMax: 900
//     )
    
//     // Helper to create a dummy unit and context
//     func makeFrame(index: Int) -> (InferenceUnit, InferenceContext) {
//         let size = 40 * 40 * 3
//         // Put the index in the first byte for verification
//         var data = Data(repeating: 0, count: size)
//         data[0] = UInt8(index % 255)
        
//         let unit = InferenceUnit.rgbData(data)
//         let context = InferenceContext(
//             timestamp: Double(index) * 0.033,
//             orientation: .up,
//             isMirrored: false,
//             roi: .zero
//         )
//         return (unit, context)
//     }
    
//     func testInitialization() async {
//         let buffer = FrameBuffer(roi: .zero, mode: .stream, config: config, constraints: constraints)
        
//         // Mode is now required
//         let ready = await buffer.isReady(hasState: false)
//         XCTAssertFalse(ready, "Buffer should not be ready initially")
//     }
    
//     func testAppendAndReadyLogic() async {
//         let buffer = FrameBuffer(roi: .zero, mode: .stream, config: config, constraints: constraints)
        
//         // 1. Initial State (No external state): Needs 16 frames (minNoState)
//         for i in 0..<15 {
//             let (unit, ctx) = makeFrame(index: i)
//             await buffer.append(unit: unit, context: ctx)
//         }
        
//         let readyNoState = await buffer.isReady(hasState: false)
//         XCTAssertFalse(readyNoState, "Should wait for 16 frames when no state exists")
        
//         // With state, 15 frames > 4 (streamMinWithState), so it WOULD be ready.
//         let readyWithState = await buffer.isReady(hasState: true)
//         XCTAssertTrue(readyWithState, "Should be ready with 15 frames if state context exists")
        
//         // Add 16th frame
//         let (unit, ctx) = makeFrame(index: 15)
//         await buffer.append(unit: unit, context: ctx)
        
//         let readyAfter = await buffer.isReady(hasState: false)
//         XCTAssertTrue(readyAfter, "Should be ready at 16 frames (Stateless threshold)")
//     }
    
//     func testConsumeMaintainsOverlap() async {
//         let buffer = FrameBuffer(roi: .zero, mode: .stream, config: config, constraints: constraints)
        
//         // Fill 16 frames (indices 0...15)
//         for i in 0..<16 {
//             let (unit, ctx) = makeFrame(index: i)
//             await buffer.append(unit: unit, context: ctx)
//         }
        
//         // Consume (Simulating a successful stateless request)
//         guard let payload1 = await buffer.consume() else {
//             XCTFail("Should have consumed"); return
//         }
//         XCTAssertEqual(payload1.count, 16)
        
//         // Verify Content (Index 0 to 15)
//         if case .rgbData(let d) = payload1.first?.unit { XCTAssertEqual(d[0], 0) }
//         if case .rgbData(let d) = payload1.last?.unit { XCTAssertEqual(d[0], 15) }
        
//         // Now simulate the Application Loop:
//         // Buffer should retain (nInputs - 1) = 3 frames.
//         // Retained indices: 13, 14, 15.
        
//         // Add 1 new frame (16)
//         let (unit, ctx) = makeFrame(index: 16)
//         await buffer.append(unit: unit, context: ctx)
        
//         // Total internal buffer is now 4 frames: [13, 14, 15, 16]
        
//         // Check Ready with State
//         let readyStateful = await buffer.isReady(hasState: true)
//         XCTAssertTrue(readyStateful, "Should be ready immediately with state + 4 frames total")
        
//         // Check Ready WITHOUT State (e.g. if API call failed)
//         let readyStateless = await buffer.isReady(hasState: false)
//         XCTAssertFalse(readyStateless, "Should NOT be ready if state was lost (needs 16 frames again)")
        
//         // Consume second batch
//         guard let payload2 = await buffer.consume() else {
//             XCTFail("Should have consumed batch 2"); return
//         }
//         XCTAssertEqual(payload2.count, 4)
        
//         // Verify Overlap: First frame of payload2 should be index 13
//         if case .rgbData(let d) = payload2.first?.unit {
//             XCTAssertEqual(d[0], 13, "Buffer did not maintain correct overlap context")
//         }
//         // Verify New Data: Last frame should be 16
//         if case .rgbData(let d) = payload2.last?.unit {
//             XCTAssertEqual(d[0], 16)
//         }
//     }
    
//     func testClear() async {
//         let buffer = FrameBuffer(roi: .zero, mode: .stream, config: config, constraints: constraints)
        
//         for i in 0..<16 {
//             let (unit, ctx) = makeFrame(index: i)
//             await buffer.append(unit: unit, context: ctx)
//         }
        
//         let readyBefore = await buffer.isReady(hasState: false)
//         XCTAssertTrue(readyBefore)
        
//         await buffer.clear()
        
//         let readyAfter = await buffer.isReady(hasState: false)
//         XCTAssertFalse(readyAfter)
        
//         // Verify behavior after clear
//         for i in 0..<4 {
//             let (unit, ctx) = makeFrame(index: i)
//             await buffer.append(unit: unit, context: ctx)
//         }
        
//         // If we don't have state, 4 frames isn't enough (need 16)
//         let readyStateless = await buffer.isReady(hasState: false)
//         XCTAssertFalse(readyStateless)
        
//         // If we DO have state, 4 frames IS enough (minWithState is 4)
//         let readyStateful = await buffer.isReady(hasState: true)
//         XCTAssertTrue(readyStateful)
//     }
    
//     func testOverflowProtection() async {
//         // Logic in FrameBuffer: if count > streamMax * 2 (300), drop frames.
//         let buffer = FrameBuffer(roi: .zero, mode: .stream, config: config, constraints: constraints)
        
//         // Append 500 frames
//         for i in 0..<500 {
//             let (unit, ctx) = makeFrame(index: i)
//             await buffer.append(unit: unit, context: ctx)
//         }
        
//         let ready = await buffer.isReady(hasState: false)
//         XCTAssertTrue(ready)
        
//         guard let payload = await buffer.consume() else { return }
        
//         // The buffer caps at roughly streamMax * 2 (300).
//         // It drops the oldest, keeping the NEWEST frames + nInputs safety.
//         // We verify that we didn't crash and returned a clamped amount.
//         let maxLimit = constraints.streamMax * 2
//         XCTAssertLessThanOrEqual(payload.count, maxLimit + 10, "Payload exceeded safe memory limits")
        
//         // Verify we kept the LATEST data
//         if case .rgbData(let d) = payload.last?.unit {
//             XCTAssertEqual(d[0], 244) // 499 % 255 = 244
//         }
//     }
// }