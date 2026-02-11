import XCTest
@testable import VitalLensCore

final class ROICalculatorTests: XCTestCase {

    // MARK: - Helpers

    /// Helper to validate ROI expansion logic using absolute pixel coordinates.
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
        
        // 4. Assert with tolerance
        XCTAssertEqual(resultPixels.origin.x, expectedRect.origin.x, accuracy: 0.1, "X mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.origin.y, expectedRect.origin.y, accuracy: 0.1, "Y mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.width, expectedRect.width, accuracy: 0.1, "Width mismatch", file: file, line: line)
        XCTAssertEqual(resultPixels.height, expectedRect.height, accuracy: 0.1, "Height mismatch", file: file, line: line)
    }

    // MARK: - ROI Expansion Tests

    func testCalculateROI_StandardCase() {
        // Verifies the "upper_body_cropped" expansion constants:
        // Insets: [Left: 0.19, Top: 0.1455, Right: 0.19, Bottom: 0.2769] relative to width/height
        assertROI(
            inputRect: CGRect(x: 100, y: 100, width: 80, height: 120),
            frameSize: CGSize(width: 220, height: 300),
            expectedRect: CGRect(x: 84.8, y: 82.54, width: 110.4, height: 170.688)
        )
    }
    
    func testCalculateROI_Clamping() {
        // Test a face at the top-left edge (0,0).
        // Expansion should clamp to 0.0, not negative.
        // Left expand: 19px -> clamped to 0.
        // Top expand: 14.55px -> clamped to 0.
        // Right expand: 19px -> 119px.
        // Bottom expand: 27.69px -> 127.69px.
        
        assertROI(
            inputRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            frameSize: CGSize(width: 1000, height: 1000),
            expectedRect: CGRect(x: 0, y: 0, width: 119.0, height: 127.69)
        )
    }
    
    // MARK: - IoU Tests
    
    func testComputeIoU() {
        // 1. Exact Match -> 1.0
        let rectA = CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)
        XCTAssertEqual(ROICalculator.computeIoU(rectA, rectA), 1.0, accuracy: 0.0001)

        // 2. No Overlap -> 0.0
        let rectB = CGRect(x: 0.5, y: 0.5, width: 0.2, height: 0.2)
        XCTAssertEqual(ROICalculator.computeIoU(rectA, rectB), 0.0, accuracy: 0.0001)

        // 3. Partial Overlap (Half area overlap)
        // Rect 1: (0,0) 10x10 -> Area 100
        // Rect 2: (5,0) 10x10 -> Area 100
        // Intersect: (5,0) 5x10 -> Area 50
        // Union: 100 + 100 - 50 = 150
        // IoU: 50 / 150 = 0.3333...
        let rectC = CGRect(x: 0.0, y: 0.0, width: 0.1, height: 0.1)
        let rectD = CGRect(x: 0.05, y: 0.0, width: 0.1, height: 0.1)
        XCTAssertEqual(ROICalculator.computeIoU(rectC, rectD), 1.0/3.0, accuracy: 0.0001)
        
        // 4. Containment (Small inside Big)
        // Big: 10x10 (Area 100)
        // Small: 5x5 (Area 25) inside
        // Intersect: 25
        // Union: 100 + 25 - 25 = 100
        // IoU: 25 / 100 = 0.25
        let big = CGRect(x: 0, y: 0, width: 0.1, height: 0.1)
        let small = CGRect(x: 0, y: 0, width: 0.05, height: 0.05)
        XCTAssertEqual(ROICalculator.computeIoU(big, small), 0.25, accuracy: 0.0001)
    }
}