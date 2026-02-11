import XCTest
@testable import VitalLensCore

final class BufferManagerTests: XCTestCase {
    
    let config = ModelConfig(
        nInputs: 4,
        inputSize: 40,
        fpsTarget: 30,
        roiMethod: "face",
        supportedVitals: ["heart_rate"]
    )

    let constraints = BatchConstraints(
        streamMinNoState: 16,
        streamMinWithState: 4,
        streamMax: 150
    )
    
    // Helper to generate a dummy frame
    func makeFrame() -> (InferenceUnit, InferenceContext) {
        let size = 40 * 40 * 3
        let unit = InferenceUnit.rgbData(Data(repeating: 0, count: size))
        let context = InferenceContext(timestamp: 0, orientation: .up, isMirrored: false, roi: .zero)
        return (unit, context)
    }
    
    // MARK: - Tracking Logic
    
    func testCreateNewBuffer() async {
        let manager = BufferManager()
        
        // 1. New Face at (0.4, 0.4)
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 2. Run update
        let activeROIs = await manager.updateAndGetActiveROIs(
            targets: [face],
            constraints: constraints,
            config: config
        )
        
        XCTAssertEqual(activeROIs.count, 1, "Should create exactly 1 buffer for a new face")
        
        // 3. Verify ROI matches input (manager uses target directly for new buffers)
        XCTAssertEqual(activeROIs.first!.roi.origin.x, 0.4, accuracy: 0.001)
    }
    
    func testTrackingStableFace() async {
        let manager = BufferManager()
        
        // 1. Initial Face
        let face1 = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let rois1 = await manager.updateAndGetActiveROIs(
            targets: [face1],
            constraints: constraints,
            config: config
        )
        let id1 = rois1.first!.id
        
        // 2. Moved Face (Slight move to 0.42, IoU > 0.6)
        let face2 = CGRect(x: 0.42, y: 0.42, width: 0.2, height: 0.2)
        
        let rois2 = await manager.updateAndGetActiveROIs(
            targets: [face2],
            constraints: constraints,
            config: config
        )
        
        XCTAssertEqual(rois2.count, 1, "Should maintain the existing buffer for slight movement")
        XCTAssertEqual(rois2.first!.id, id1, "Should return the SAME buffer ID")
    }
    
    func testDriftCreatesNewBuffer() async {
        let manager = BufferManager()
        
        // 1. Face Left
        let faceLeft = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        _ = await manager.updateAndGetActiveROIs(
            targets: [faceLeft],
            constraints: constraints,
            config: config
        )
        
        // 2. Face Right (Far jump, IoU = 0)
        let faceRight = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        
        // Pass BOTH faces (simulating drift logic where old face is gone, new face appears)
        // If we just pass faceRight, the manager might drop the old buffer if it times out, 
        // but here we are checking immediate creation.
        let rois = await manager.updateAndGetActiveROIs(
            targets: [faceRight],
            constraints: constraints,
            config: config
        )
        
        // In the new logic, updateAndGetActiveROIs returns active buffers for the CURRENT targets.
        // It does NOT return "all buffers including timed-out ones".
        // So we expect 1 buffer (the new one).
        // BUT, the old buffer still exists inside the manager until it times out (5s).
        
        XCTAssertEqual(rois.count, 1, "Should return ROI for the active target")
        XCTAssertNotEqual(rois.first?.roi.origin.x, 0.1, "Should correspond to the new face")
    }
    
    // MARK: - State & Ready Logic
    
    func testStateInjectionIntoReadyCheck() async {
        let manager = BufferManager()
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 1. Create Buffer
        let rois = await manager.updateAndGetActiveROIs(
            targets: [face],
            constraints: constraints,
            config: config
        )
        let id = rois.first!.id
        
        // 2. Add 15 frames
        for _ in 0..<15 {
            let (unit, ctx) = makeFrame()
            await manager.append(bufferId: id, unit: unit, context: ctx)
        }
        
        // 3. Check Ready (Should be FALSE, because we have no state, need 16)
        let ready1 = await manager.getReadyBuffer(mode: .stream)
        XCTAssertNil(ready1, "Should be nil (15 < 16)")
        
        // 4. Inject State (Using APIState wrapper)
        let dummyState = APIState(data: [0.1, 0.2, 0.3])
        await manager.updateState(dummyState)
        
        // 5. Check Ready (Should be TRUE, because we have state, need 4. 15 > 4)
        let ready2 = await manager.getReadyBuffer(mode: .stream)
        XCTAssertNotNil(ready2, "Should be ready now that state is injected")
        
        if let buffer = ready2 {
            let bufferROI = await buffer.roi
            XCTAssertEqual(bufferROI, rois.first!.roi)
        }
    }
    
    func testGetReadyBufferPrioritizesNewest() async {
        let manager = BufferManager()
        
        // Buffer A (Old)
        let faceA = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let roisA = await manager.updateAndGetActiveROIs(
            targets: [faceA],
            constraints: constraints,
            config: config
        )
        let idA = roisA.first!.id
        
        // Wait a tiny bit to ensure timestamp difference
        try? await Task.sleep(nanoseconds: 10_000_000)
        
        // Buffer B (New)
        let faceB = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        let roisB = await manager.updateAndGetActiveROIs(
            targets: [faceB],
            constraints: constraints,
            config: config
        )
        let idB = roisB.first!.id
        
        // Fill both buffers to readiness (16 frames)
        for _ in 0..<16 {
            let (unit, ctx) = makeFrame()
            await manager.append(bufferId: idA, unit: unit, context: ctx)
            await manager.append(bufferId: idB, unit: unit, context: ctx)
        }
        
        // Get Ready. Should return B because it is newer.
        let bestBuffer = await manager.getReadyBuffer(mode: .stream)
        XCTAssertNotNil(bestBuffer)
        
        if let buffer = bestBuffer {
            let bestROI = await buffer.roi
            XCTAssertGreaterThan(bestROI.origin.x, 0.5, "Should pick the new buffer (Right side)")
        }
    }
    
    // MARK: - Robustness & Lifecycle
    
    func testNilTargetsDoesNotReturnBuffers() async {
        let manager = BufferManager()
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 1. Establish a buffer
        _ = await manager.updateAndGetActiveROIs(
            targets: [face],
            constraints: constraints,
            config: config
        )
        
        // 2. Simulate detection failure (empty targets)
        let rois2 = await manager.updateAndGetActiveROIs(
            targets: [],
            constraints: constraints,
            config: config
        )
        
        // Assertion: updateAndGetActiveROIs returns *requested* active ROIs.
        // If we request nothing, we get nothing back.
        // However, the internal buffer persists until timeout.
        XCTAssertTrue(rois2.isEmpty, "Should return no active ROIs if no targets provided")
    }
    
    func testResetClearsState() async {
        let manager = BufferManager()
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 1. Create state
        _ = await manager.updateAndGetActiveROIs(
            targets: [face],
            constraints: constraints,
            config: config
        )
        await manager.updateState(APIState(data: [0.1]))
        
        // 2. Reset
        await manager.reset()
        
        // 3. Verify
        let state = await manager.getState()
        XCTAssertNil(state, "RNN state should be nil after reset")
        
        // Verify buffers are gone (by trying to get ready buffer)
        let ready = await manager.getReadyBuffer(mode: .stream)
        XCTAssertNil(ready)
    }
}