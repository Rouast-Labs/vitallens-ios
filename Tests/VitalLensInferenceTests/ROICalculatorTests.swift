import XCTest
import CoreGraphics
@testable import VitalLensInference

final class ROICalculatorTests: XCTestCase {
    
    // MARK: - ROI Calculation
    
    func testCalculateROI_StandardMethods() {
        let input = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        
        let methods = ["face", "forehead", "upper_body", "upper_body_cropped"]
        
        for method in methods {
            let result = ROICalculator.calculateROI(from: input, method: method)
            
            XCTAssertGreaterThanOrEqual(result.minX, 0.0)
            XCTAssertLessThanOrEqual(result.maxX, 1.0)
            XCTAssertGreaterThan(result.width, 0.0)
            XCTAssertGreaterThan(result.height, 0.0)
            XCTAssertNotEqual(input, result, "ROI calculation for \(method) should transform the input rect")
        }
    }
    
    func testCalculateROI_FallbackLogic() {
        let input = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        
        let expectedFallback = ROICalculator.calculateROI(from: input, method: "upper_body_cropped")
        let resultInvalid = ROICalculator.calculateROI(from: input, method: "undefined_method_string")
        
        XCTAssertEqual(resultInvalid, expectedFallback, "Unknown methods should fallback to upper_body_cropped")
    }
    
    // MARK: - IoU Math
    
    func testComputeIoU_Values() {
        // No overlap
        let a = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let b = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        XCTAssertEqual(ROICalculator.computeIoU(a, b), 0.0)
        
        // Full overlap
        let c = CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3)
        XCTAssertEqual(ROICalculator.computeIoU(c, c), 1.0, accuracy: 0.001)
        
        // Partial overlap (Area 0.01 / Union 0.03)
        let rect1 = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.1)
        let rect2 = CGRect(x: 0.1, y: 0.0, width: 0.2, height: 0.1)
        XCTAssertEqual(ROICalculator.computeIoU(rect1, rect2), 0.333, accuracy: 0.001)
    }
}