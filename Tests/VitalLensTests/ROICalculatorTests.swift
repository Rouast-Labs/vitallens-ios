import XCTest
@testable import VitalLensCore

final class ROICalculatorTests: XCTestCase {

    // MARK: - Helper for JS Parity
    
    /// Runs a test case using absolute pixel values (matching vitallens.js tests).
    /// Internally converts to normalized coordinates (0-1), runs the logic, and converts back for assertion.
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

    // MARK: - Ported JS Tests

    func testGetFaceROI() {
        // JS: det = { x0: 100, y0: 100, x1: 180, y1: 220 } -> w: 80, h: 120
        // JS: clipDims = { width: 220, height: 300 }
        // JS Result: { x0: 116, y0: 112, x1: 164, y1: 208 } -> w: 48, h: 96
        
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            method: "face",
            expectedRect: CGRect(x: 116, y: 112, width: 48, height: 96)
        )
    }

    func testGetForeheadROI() {
        // JS: det = { x0: 100, y0: 100, x1: 180, y1: 220 } -> w: 80, h: 120
        // JS: clipDims = { width: 220, height: 300 }
        // JS Result: { x0: 128, y0: 118, x1: 152, y1: 130 } -> w: 24, h: 12
        
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            method: "forehead",
            expectedRect: CGRect(x: 128, y: 118, width: 24, height: 12)
        )
    }

    func testGetUpperBodyROI_Cropped() {
        // JS: det = { x0: 100, y0: 100, x1: 180, y1: 220 } -> w: 80, h: 120
        // JS: clipDims = { width: 220, height: 300 }
        // JS Result: { x0: 85, y0: 83, x1: 195, y1: 253 } -> w: 110, h: 170
        // Note: JS `calculateROI` usually defaults to the "cropped" variant of Upper Body
        
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            method: "upper_body_cropped",
            expectedRect: CGRect(x: 85, y: 83, width: 110, height: 170)
        )
    }
    
    // MARK: - Validation Tests (checkFaceInROI)
    
    func testCheckFaceInROI() {
        // We simulate the normalized logic here directly as the helper is for calculateROI
        
        // JS: face = { x0: 10, y0: 10, x1: 19, y1: 19 } (w: 9, h: 9)
        // JS: roi = { x0: 0, y0: 0, x1: 30, y1: 30 }
        // JS: expect(true)
        let facePass = CGRect(x: 0.1, y: 0.1, width: 0.09, height: 0.09)
        let roiPass = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
        XCTAssertTrue(ROICalculator.isFace(facePass, sufficientlyInsideROI: roiPass))
        
        // JS: face = { x0: 22, y0: 22, x1: 40, y1: 40 } (w: 18, h: 18)
        // JS: roi = { x0: 0, y0: 0, x1: 30, y1: 30 }
        // JS: expect(false) -- Face extends beyond ROI (40 > 30)
        let faceFail = CGRect(x: 0.22, y: 0.22, width: 0.18, height: 0.18)
        let roiFail = CGRect(x: 0.0, y: 0.0, width: 0.3, height: 0.3)
        XCTAssertFalse(ROICalculator.isFace(faceFail, sufficientlyInsideROI: roiFail))
    }
}