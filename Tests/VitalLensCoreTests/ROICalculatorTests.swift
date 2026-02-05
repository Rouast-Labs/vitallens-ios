import XCTest
@testable import VitalLensCore

final class ROICalculatorTests: XCTestCase {

    // MARK: - Helper
    
    /// Runs a test case using absolute pixel values
    private func assertROI(
        inputRect: CGRect,
        frameSize: CGSize,
        method: String,
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
            method: method,
            frameSize: frameSize
        )
        
        // 3. Denormalize Output (0.0-1.0 -> Pixels)
        // We round to match the integer-pixel logic of the JS tests
        let resultPixels = CGRect(
            x: (normalizedResult.origin.x * frameSize.width),
            y: (normalizedResult.origin.y * frameSize.height),
            width: (normalizedResult.width * frameSize.width),
            height: (normalizedResult.height * frameSize.height)
        )
        
        // 4. Assert
        // Accuracy of 0.5 allows for float floating point precision issues during the round-trip
        XCTAssertEqual(resultPixels.origin.x, expectedRect.origin.x, accuracy: 0.5, "X mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.origin.y, expectedRect.origin.y, accuracy: 0.5, "Y mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.width, expectedRect.width, accuracy: 0.5, "Width mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.height, expectedRect.height, accuracy: 0.5, "Height mismatch", file: file, line: line)
    }

    // MARK: - Tests

    func testGetFaceROI() {
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            method: "face",
            expectedRect: CGRect(x: 116, y: 112, width: 48, height: 96)
        )
    }

    func testGetForeheadROI() {
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            method: "forehead",
            expectedRect: CGRect(x: 128, y: 118, width: 24, height: 12)
        )
    }

    func testGetUpperBodyROI_Cropped() {
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            method: "upper_body_cropped",
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