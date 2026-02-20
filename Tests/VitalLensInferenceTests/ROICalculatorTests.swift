import XCTest
import CoreGraphics
@testable import VitalLensInference

final class ROICalculatorTests: XCTestCase {
    
    // MARK: - calculateROI Tests
    
    func testCalculateROI_FaceMethod() {
        let input = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let result = ROICalculator.calculateROI(from: input, method: "face")
        
        // Assert it bounded the output safely within the 1.0 container limits
        XCTAssertGreaterThanOrEqual(result.minX, 0.0)
        XCTAssertLessThanOrEqual(result.maxX, 1.0)
        XCTAssertGreaterThan(result.width, 0.0)
        XCTAssertGreaterThan(result.height, 0.0)
        
        // Assert the FFI mutation occurred
        XCTAssertNotEqual(input, result)
    }
    
    func testCalculateROI_ForeheadMethod() {
        let input = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let result = ROICalculator.calculateROI(from: input, method: "forehead")
        
        XCTAssertGreaterThan(result.width, 0.0)
        XCTAssertGreaterThan(result.height, 0.0)
        XCTAssertNotEqual(input, result)
    }
    
    func testCalculateROI_UpperBodyMethod() {
        let input = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        let result = ROICalculator.calculateROI(from: input, method: "upper_body")
        
        // Upper body expansion should result in larger dimensions
        XCTAssertGreaterThan(result.width, input.width)
        XCTAssertGreaterThan(result.height, input.height)
    }
    
    func testCalculateROI_FallbackMethod() {
        let input = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        
        let resultExpectedFallback = ROICalculator.calculateROI(from: input, method: "upper_body_cropped")
        let resultInvalid = ROICalculator.calculateROI(from: input, method: "some_unknown_string")
        
        // The switch statement should gracefully default to upper_body_cropped
        XCTAssertEqual(resultInvalid, resultExpectedFallback)
    }
    
    // MARK: - computeIoU Tests
    
    func testComputeIoU_NoOverlap() {
        let a = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        
        let iou = ROICalculator.computeIoU(a, b)
        XCTAssertEqual(iou, 0.0)
    }
    
    func testComputeIoU_FullOverlap() {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        let b = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        
        let iou = ROICalculator.computeIoU(a, b)
        XCTAssertEqual(iou, 1.0, accuracy: 0.0001)
    }
    
    func testComputeIoU_PartialOverlap() {
        let a = CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1) // Area: 0.01
        let b = CGRect(x: 0.05, y: 0.0, width: 0.1, height: 0.1) // Shifted 50% right
        
        // Intersection = 0.05 * 0.1 = 0.005
        // Union = 0.01 + 0.01 - 0.005 = 0.015
        // IoU = 0.005 / 0.015 = 1/3
        
        let iou = ROICalculator.computeIoU(a, b)
        XCTAssertEqual(iou, 0.333333, accuracy: 0.001)
    }
}