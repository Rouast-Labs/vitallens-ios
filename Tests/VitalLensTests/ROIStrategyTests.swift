import XCTest
import CoreVideo
import ImageIO
import VitalLensInference
@testable import VitalLens

final class ROIStrategyTests: XCTestCase {
    
    func testDetermineROI_FirstCall_TriggersDetection() async throws {
        let expectedRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let mockDetector = MockFaceDetector(rects: [expectedRect]) 
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.5)
        let buffer = createDummyBuffer()
        
        // Act 1: Detection starts but returns immediately
        let initialROI = await strategy.determineROI(in: buffer, orientation: .up)
        XCTAssertNil(initialROI)
        
        // Let async detection finish
        try await Task.sleep(nanoseconds: 100_000_000) 
        
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 1)
        
        // Act 2: Next frame gets the populated result
        let subsequentROI = await strategy.determineROI(in: buffer, orientation: .up)
        XCTAssertEqual(subsequentROI, expectedRect)
    }
    
    func testDetermineROI_Throttling_PreventsRapidCalls() async throws {
        let mockDetector = MockFaceDetector(rects: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 1.0)
        let buffer = createDummyBuffer()
        
        _ = await strategy.determineROI(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000) 
        
        _ = await strategy.determineROI(in: buffer, orientation: .up)
        _ = await strategy.determineROI(in: buffer, orientation: .up)
        
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 1, "Should not re-trigger detection before interval elapses")
    }
    
    func testDetermineROI_UpdatesAfterInterval() async throws {
        let rect1 = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let rect2 = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        
        let mockDetector = MockFaceDetector(rects: [rect1, rect2]) 
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.1)
        let buffer = createDummyBuffer()
        
        // 1. First Call
        _ = await strategy.determineROI(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let roi1 = await strategy.determineROI(in: buffer, orientation: .up)
        XCTAssertEqual(roi1, rect1)
        
        // 2. Wait past interval
        try await Task.sleep(nanoseconds: 150_000_000) 
        
        // 3. Second Call triggers next detection
        _ = await strategy.determineROI(in: buffer, orientation: .up)
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // 4. Verify
        let roi2 = await strategy.determineROI(in: buffer, orientation: .up)
        XCTAssertEqual(roi2, rect2)
        
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 2)
    }
    
    func testDetermineROI_DropsROIImmediatelyOnFailure() async throws {
        let validRect = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        // We provide enough mock responses for 3 detection cycles
        let mockDetector = MockFaceDetector(rects: [validRect, nil, nil])  
        
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.1)
        let buffer = createDummyBuffer()
        
        // 1. First call triggers Detection #1. It returns nil immediately (default).
        _ = await strategy.determineROI(in: buffer, orientation: .up) 
        
        // Wait for Detection #1 to finish setting `currentROI = validRect`
        try await Task.sleep(nanoseconds: 120_000_000)
        
        // 2. Second call returns the result of Detection #1 (validRect) AND triggers Detection #2.
        let roi1 = await strategy.determineROI(in: buffer, orientation: .up) 
        XCTAssertEqual(roi1, validRect)
        
        // Wait for Detection #2 to finish setting `currentROI = nil`
        try await Task.sleep(nanoseconds: 120_000_000)
        
        // 3. Third call returns the result of Detection #2 (nil) AND triggers Detection #3.
        let roi2 = await strategy.determineROI(in: buffer, orientation: .up)
        XCTAssertNil(roi2, "Should immediately drop the ROI if detection fails")
        
        // Yield the thread for a fraction of a second so the internal Task has time to hit the mock detector
        try await Task.sleep(nanoseconds: 50_000_000)
        
        // 4. Verify we hit the detector exactly 3 times across these intervals
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 3, "Should have triggered detection 3 times")
    }
    
    // MARK: - Helpers
    
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