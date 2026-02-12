import XCTest
import CoreVideo
import ImageIO
import VitalLensCore
@testable import VitalLens

final class ROIStrategyTests: XCTestCase {
    
    // MARK: - FaceROIStrategy Tests
    
    func testDetermineROIs_FirstCall_TriggersDetection() async throws {
        // Arrange
        let expectedRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let mockDetector = MockFaceDetector(rects: [expectedRect]) 
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.5)
        let buffer = createDummyBuffer()
        
        // Act 1
        let initialROIs = await strategy.determineROIs(in: buffer, orientation: .up)
        XCTAssertTrue(initialROIs.isEmpty)
        
        // Wait for background Task
        try await Task.sleep(nanoseconds: 100_000_000) 
        
        // Assert
        // FIX: Await actor property into local variable
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 1)
        
        // Act 2
        let subsequentROIs = await strategy.determineROIs(in: buffer, orientation: .up)
        XCTAssertEqual(subsequentROIs.first, expectedRect)
    }
    
    func testDetermineROIs_Throttling_PreventsRapidCalls() async throws {
        let mockDetector = MockFaceDetector(rects: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 1.0)
        let buffer = createDummyBuffer()
        
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000) 
        
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        
        // FIX: Await actor property into local variable
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 1, "Should not re-trigger detection before interval elapses")
    }
    
    func testDetermineROIs_UpdatesAfterInterval() async throws {
        let rect1 = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let rect2 = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        
        let mockDetector = MockFaceDetector(rects: [rect1, rect2]) 
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.1)
        let buffer = createDummyBuffer()
        
        // 1. First Call
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let rois1 = await strategy.determineROIs(in: buffer, orientation: .up)
        XCTAssertEqual(rois1.first, rect1)
        
        // 2. Wait
        try await Task.sleep(nanoseconds: 150_000_000) 
        
        // 3. Second Call
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // 4. Verify
        let rois2 = await strategy.determineROIs(in: buffer, orientation: .up)
        XCTAssertEqual(rois2.first, rect2)
        
        // FIX: Await actor property into local variable
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 2)
    }
    
    func testDetermineROIs_Stability_KeepsOldROIOnFailure() async throws {
        let validRect = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let mockDetector = MockFaceDetector(rects: [validRect, nil])
        
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.05)
        let buffer = createDummyBuffer()
        
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 60_000_000)
        
        let rois1 = await strategy.determineROIs(in: buffer, orientation: .up)
        XCTAssertEqual(rois1.first, validRect)
        
        _ = await strategy.determineROIs(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let rois2 = await strategy.determineROIs(in: buffer, orientation: .up)
        XCTAssertEqual(rois2.first, validRect)
        
        // FIX: Await actor property into local variable
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 2)
    }
    
    // MARK: - Helpers & Mocks
    
    private func createDummyBuffer() -> SendablePixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 100, 100, kCVPixelFormatType_32BGRA, nil, &buffer)
        return SendablePixelBuffer(buffer!)
    }
    
    actor MockFaceDetector: FaceDetecting {
        var callCount = 0
        private var rects: [CGRect?]
        
        init(rects: [CGRect?]) {
            self.rects = rects
        }
        
        func detectFace(in pixelBuffer: SendablePixelBuffer, orientation: CGImagePropertyOrientation) async throws -> CGRect? {
            callCount += 1
            if !rects.isEmpty {
                return rects.removeFirst()
            }
            return nil
        }
    }
}