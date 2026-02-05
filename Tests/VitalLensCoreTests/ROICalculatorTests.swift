import XCTest
@testable import VitalLensCore

final class ROICalculatorTests: XCTestCase {

    // MARK: - Helper
    
    /// Runs a test case using absolute pixel values
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
        
        // 2. Run Logic (Method string is ignored now)
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
        
        // 4. Assert
        XCTAssertEqual(resultPixels.origin.x, expectedRect.origin.x, accuracy: 0.5, "X mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.origin.y, expectedRect.origin.y, accuracy: 0.5, "Y mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.width, expectedRect.width, accuracy: 0.5, "Width mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.height, expectedRect.height, accuracy: 0.5, "Height mismatch", file: file, line: line)
    }

    // MARK: - Tests

    func testGetUpperBodyROI_Cropped() {
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            // Expected calculation based on [0.19, 0.1455, 0.19, 0.2769] insets
            // Left shift: 0.19 * 80 = 15.2 -> 15. X becomes 85.
            // Top shift: 0.1455 * 120 = 17.46 -> 17. Y becomes 83.
            // Right shift: 0.19 * 80 = 15.2 -> 15. Width adds 15+15 = 30. Total 110.
            // Bottom shift: 0.2769 * 120 = 33.2 -> 33. Height adds 17+33 = 50. Total 170.
            expectedRect: CGRect(x: 85, y: 83, width: 110, height: 170)
        )
    }
    
    // MARK: - Validation Tests (checkFaceInROI)
    
    func testCheckFaceInROI() {
        let facePass = CGRect(x: 0.1, y: 0.1, width: 0.09, height: 0.09)
        let roiPass = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
        XCTAssertTrue(ROICalculator.isFace(facePass, sufficientlyInsideROI: roiPass))
        
        let faceFail = CGRect(x: 0.22, y: 0.22, width: 0.18, height: 0.18)
        let roiFail = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
        XCTAssertFalse(ROICalculator.isFace(faceFail, sufficientlyInsideROI: roiFail))
    }
}