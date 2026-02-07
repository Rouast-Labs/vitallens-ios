import XCTest
@testable import VitalLensCore

final class ROICalculatorTests: XCTestCase {

    // MARK: - Helper
    
    /// Runs a test case using absolute pixel values for easier verification.
    /// Internally converts to/from normalized coordinates to test the logic.
    private func assertROI(
        inputRect: CGRect,
        frameSize: CGSize,
        expectedRect: CGRect,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        // 1. Normalize Input (Pixels -> 0.0-1.0)
        let normalizedInput = CGRect(
            x: inputRect.origin.x / frameSize.width,
            y: inputRect.origin.y / frameSize.height,
            width: inputRect.width / frameSize.width,
            height: inputRect.height / frameSize.height
        )
        
        // 2. Run Logic
        let normalizedResult = ROICalculator.calculateROI(
            from: normalizedInput,
            method: "upper_body_cropped", 
            frameSize: frameSize
        )
        
        // 3. Denormalize Output (0.0-1.0 -> Pixels)
        let resultPixels = CGRect(
            x: (normalizedResult.origin.x * frameSize.width),
            y: (normalizedResult.origin.y * frameSize.height),
            width: (normalizedResult.width * frameSize.width),
            height: (normalizedResult.height * frameSize.height)
        )
        
        // 4. Assert with tolerance for float arithmetic
        XCTAssertEqual(resultPixels.origin.x, expectedRect.origin.x, accuracy: 0.01, "X mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.origin.y, expectedRect.origin.y, accuracy: 0.01, "Y mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.width, expectedRect.width, accuracy: 0.01, "Width mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.height, expectedRect.height, accuracy: 0.01, "Height mismatch", file: file, line: line)
    }

    // MARK: - ROI Calculation Tests

    func testGetUpperBodyROI_Cropped() {
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            expectedRect: CGRect(x: 84.8, y: 82.54, width: 110.4, height: 170.688)
        )
    }
    
    // MARK: - Validation Tests (isFace)
    
    func testCheckFaceInROI() {
        // A face fully inside the ROI should pass
        let facePass = CGRect(x: 0.1, y: 0.1, width: 0.09, height: 0.09)
        let roiPass = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
        XCTAssertTrue(ROICalculator.isFace(facePass, sufficientlyInsideROI: roiPass))
        
        // A face mostly outside the ROI should fail
        let faceFail = CGRect(x: 0.22, y: 0.22, width: 0.18, height: 0.18)
        let roiFail = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
        XCTAssertFalse(ROICalculator.isFace(faceFail, sufficientlyInsideROI: roiFail))
    }
}