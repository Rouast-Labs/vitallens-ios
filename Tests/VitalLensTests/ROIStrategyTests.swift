import XCTest
import CoreVideo
import ImageIO
import VitalLensInference
@testable import VitalLens

final class ROIStrategyTests: XCTestCase {
    
    func testDetermineROI_FirstCall_TriggersDetection() async throws {
        let rawRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.2)
        let expectedRect = ROICalculator.calculateROI(from: rawRect, method: "face")
        
        let mockDetector = MockFaceDetector(rects: [rawRect]) 
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.5)
        let buffer = createDummyBuffer()
        
        let initialROI = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        XCTAssertNil(initialROI)
        
        try await Task.sleep(nanoseconds: 100_000_000) 
        
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 1)
        
        let subsequentROI = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        XCTAssertEqual(subsequentROI, expectedRect)
    }
    
    func testDetermineROI_Throttling_PreventsRapidCalls() async throws {
        let mockDetector = MockFaceDetector(rects: [CGRect(x: 0, y: 0, width: 1, height: 1)])
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 1.0)
        let buffer = createDummyBuffer()
        
        _ = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        try await Task.sleep(nanoseconds: 50_000_000) 
        
        _ = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        _ = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 1, "Should not re-trigger detection before interval elapses")
    }
    
    func testDetermineROI_UpdatesAfterInterval() async throws {
        let rect1 = CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1)
        let rect2 = CGRect(x: 0.5, y: 0.5, width: 0.1, height: 0.1)
        
        let mockDetector = MockFaceDetector(rects: [rect1, rect2]) 
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.1)
        let buffer = createDummyBuffer()
        
        _ = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let roi1 = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        let expected1 = ROICalculator.calculateROI(from: rect1, method: "face")
        XCTAssertEqual(roi1, expected1)
        
        try await Task.sleep(nanoseconds: 150_000_000) 
        
        _ = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        try await Task.sleep(nanoseconds: 50_000_000)
        
        let roi2 = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        let expected2 = ROICalculator.calculateROI(from: rect2, method: "face")
        XCTAssertEqual(roi2, expected2)
        
        let count = await mockDetector.callCount
        XCTAssertEqual(count, 2)
    }
    
    func testDetermineROI_DropsROIImmediatelyOnFailure() async throws {
        let validRect = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let mockDetector = MockFaceDetector(rects: [validRect, nil, nil])  
        
        let strategy = FaceROIStrategy(detector: mockDetector, interval: 0.1)
        let buffer = createDummyBuffer()
        
        _ = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face") 
        
        try await Task.sleep(nanoseconds: 120_000_000)
        
        let roi1 = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        let expectedRect = ROICalculator.calculateROI(from: validRect, method: "face")
        XCTAssertEqual(roi1, expectedRect)
        
        try await Task.sleep(nanoseconds: 120_000_000)
        
        let roi2 = await strategy.determineROI(in: buffer, orientation: .up, isMirrored: false, roiMethod: "face")
        XCTAssertNil(roi2, "Should immediately drop the ROI if detection fails")
        
        try await Task.sleep(nanoseconds: 50_000_000)
        
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
        
        func detectFace(
            in pixelBuffer: SendablePixelBuffer, 
            orientation: CGImagePropertyOrientation, 
            isMirrored: Bool
        ) async throws -> CGRect? {
            callCount += 1
            guard !rects.isEmpty else { return nil }
            return rects.removeFirst()
        }
    }
}