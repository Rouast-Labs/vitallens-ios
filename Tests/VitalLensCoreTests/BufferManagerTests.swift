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
    
    func makeFrameData(val: UInt8) -> Data {
        let size = 40 * 40 * 3
        return Data(repeating: val, count: size)
    }
    
    // MARK: - Tracking Logic
    
    func testCreateNewBuffer() async {
        let manager = BufferManager()
        
        // 1. New Face at (0.4, 0.4)
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 2. Run update
        let activeROIs = await manager.updateAndGetActiveROIs(faceRect: face, config: config)
        
        XCTAssertEqual(activeROIs.count, 1, "Should create exactly 1 buffer for a new face")
        
        // 3. Verify ROI Logic (Approximate check based on ROICalculator logic)
        let roi = activeROIs.first!.roi
        XCTAssertEqual(roi.origin.x, 0.362, accuracy: 0.001)
    }
    
    func testTrackingStableFace() async {
        let manager = BufferManager()
        let trackConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "upper_body_cropped", supportedVitals: [])

        // 1. Initial Face
        let face1 = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let rois1 = await manager.updateAndGetActiveROIs(faceRect: face1, config: trackConfig)
        let id1 = rois1.first!.id
        
        // 2. Moved Face (Slight move to 0.42)
        let face2 = CGRect(x: 0.42, y: 0.42, width: 0.2, height: 0.2)
        let rois2 = await manager.updateAndGetActiveROIs(faceRect: face2, config: trackConfig)
        
        XCTAssertEqual(rois2.count, 1, "Should maintain the existing buffer for slight movement")
        XCTAssertEqual(rois2.first!.id, id1, "Should return the SAME buffer ID")
    }
    
    func testDriftCreatesNewBuffer() async {
        let manager = BufferManager()
        let trackConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "upper_body_cropped", supportedVitals: [])
        
        // 1. Face Left
        let faceLeft = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        _ = await manager.updateAndGetActiveROIs(faceRect: faceLeft, config: trackConfig)
        
        // 2. Face Right (Far jump)
        let faceRight = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        let rois = await manager.updateAndGetActiveROIs(faceRect: faceRight, config: trackConfig)
        
        // Expect both buffers to be active (1 old, 1 new)
        XCTAssertEqual(rois.count, 2, "Should have 2 buffers after drift")
    }
    
    // MARK: - State & Ready Logic
    
    func testStateInjectionIntoReadyCheck() async {
        let manager = BufferManager()
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 1. Create Buffer
        let rois = await manager.updateAndGetActiveROIs(faceRect: face, config: config)
        let id = rois.first!.id
        
        // 2. Add 15 frames
        for _ in 0..<15 {
            await manager.append(bufferId: id, data: makeFrameData(val: 1))
        }
        
        // 3. Check Ready (Should be FALSE, because we have no state, need 16)
        let ready1 = await manager.getReadyBuffer()
        XCTAssertNil(ready1, "Should be nil (15 < 16)")
        
        // 4. Inject State
        await manager.updateState([0.1, 0.2, 0.3])
        
        // 5. Check Ready (Should be TRUE, because we have state, need 4. 15 > 4)
        let ready2 = await manager.getReadyBuffer()
        XCTAssertNotNil(ready2, "Should be ready now that state is injected")
        
        if let buffer = ready2 {
            let bufferROI = await buffer.roi
            XCTAssertEqual(bufferROI, rois.first!.roi)
        }
    }
    
    func testGetReadyBufferPrioritizesNewest() async {
        let manager = BufferManager()
        let trackConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "upper_body_cropped", supportedVitals: [])
        
        // Buffer A (Old)
        let faceA = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let roisA = await manager.updateAndGetActiveROIs(faceRect: faceA, config: trackConfig)
        let idA = roisA.first!.id
        
        // Wait a tiny bit to ensure timestamp difference
        try? await Task.sleep(nanoseconds: 1_000_000)
        
        // Buffer B (New)
        let faceB = CGRect(x: 0.7, y: 0.7, width: 0.2, height: 0.2)
        let roisB = await manager.updateAndGetActiveROIs(faceRect: faceB, config: trackConfig)
        
        // Find B's ID (the one that isn't A)
        let idB = roisB.first(where: { $0.id != idA })!.id
        
        // Fill both buffers to readiness (16 frames)
        for _ in 0..<16 {
            await manager.append(bufferId: idA, data: makeFrameData(val: 1))
            await manager.append(bufferId: idB, data: makeFrameData(val: 2))
        }
        
        // Get Ready. Should return B because it is newer.
        let bestBuffer = await manager.getReadyBuffer()
        XCTAssertNotNil(bestBuffer)
        
        if let buffer = bestBuffer {
            let bestROI = await buffer.roi
            XCTAssertGreaterThan(bestROI.origin.x, 0.5, "Should pick the new buffer (Right side)")
        }
    }
    
    // MARK: - Robustness & Lifecycle
    
    func testNilFacePreservesBuffers() async {
        let manager = BufferManager()
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 1. Establish a buffer with a valid face
        let rois1 = await manager.updateAndGetActiveROIs(faceRect: face, config: config)
        let originalID = rois1.first?.id
        
        // 2. Simulate detection failure (nil face)
        let rois2 = await manager.updateAndGetActiveROIs(faceRect: nil, config: config)
        
        // Assertion: We must NOT lose the buffer. We should keep processing the last known ROI.
        XCTAssertEqual(rois2.count, 1, "Existing buffers should persist even if face detection misses a frame")
        XCTAssertEqual(rois2.first?.id, originalID, "The ID should remain consistent")
        XCTAssertEqual(rois2.first?.roi.origin.x, rois1.first?.roi.origin.x, "The ROI should not change")
    }
    
    func testResetClearsState() async {
        let manager = BufferManager()
        let face = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        
        // 1. Create state
        _ = await manager.updateAndGetActiveROIs(faceRect: face, config: config)
        await manager.updateState([0.1, 0.2])
        
        // 2. Reset
        await manager.reset()
        
        // 3. Verify
        let rois = await manager.updateAndGetActiveROIs(faceRect: nil, config: config)
        XCTAssertTrue(rois.isEmpty, "Buffers should be empty after reset")
        
        let state = await manager.getState()
        XCTAssertNil(state, "RNN state should be nil after reset")
    }
    
    func testBufferAccumulationOnMovement() async {
        let manager = BufferManager()
        let trackConfig = ModelConfig(nInputs: 4, inputSize: 40, fpsTarget: 30, roiMethod: "upper_body_cropped", supportedVitals: [])
        
        // Move face to 3 distinct positions (Left -> Center -> Right)
        let positions = [0.1, 0.5, 0.9]
        
        for x in positions {
            let face = CGRect(x: x, y: 0.1, width: 0.2, height: 0.2)
            _ = await manager.updateAndGetActiveROIs(faceRect: face, config: trackConfig)
        }
        
        // We expect 3 distinct buffers because we moved far enough to trigger new ones
        let finalROIs = await manager.updateAndGetActiveROIs(faceRect: nil, config: trackConfig)
        XCTAssertEqual(finalROIs.count, 3)
    }
}