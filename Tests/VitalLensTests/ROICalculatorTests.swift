import XCTest
@testable import VitalLens

final class ROICalculatorTests: XCTestCase {

    // MARK: - Method Strategy Tests

    func testFaceROIStrategy() {
        // Input: A standard face centered in the frame
        // Rect: x: 0.4, y: 0.4, w: 0.2, h: 0.2
        let faceRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let frameSize = CGSize(width: 100, height: 100) // 100x100 for easy percentage math

        // Execute
        let result = ROICalculator.calculateROI(from: faceRect, method: "face", frameSize: frameSize)

        // Expected Logic (from getFaceROI):
        // Change: [-0.2, -0.1, -0.2, -0.1] (Negative means shrink/inset)
        // newX = 0.4 - (-0.2 * 0.2) = 0.4 + 0.04 = 0.44
        // newY = 0.4 - (-0.1 * 0.2) = 0.4 + 0.02 = 0.42
        // newMaxX = 0.6 + (-0.2 * 0.2) = 0.6 - 0.04 = 0.56
        // newMaxY = 0.6 + (-0.1 * 0.2) = 0.6 - 0.02 = 0.58
        // Width = 0.56 - 0.44 = 0.12
        // Height = 0.58 - 0.42 = 0.16

        XCTAssertEqual(result.origin.x, 0.44, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 0.42, accuracy: 0.001)
        XCTAssertEqual(result.width, 0.12, accuracy: 0.001)
        XCTAssertEqual(result.height, 0.16, accuracy: 0.001)
    }

    func testUpperBodyROIStrategy() {
        // Input: A standard face
        let faceRect = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        let frameSize = CGSize(width: 100, height: 100)

        // Execute
        let result = ROICalculator.calculateROI(from: faceRect, method: "upper_body_cropped", frameSize: frameSize)

        // Expected Logic (from getUpperBodyROI cropped=true):
        // Change: [0.19, 0.1455, 0.19, 0.2769] (Positive means expand)
        // Width expansion = 0.2 * 0.19 = 0.038
        // Height top exp = 0.2 * 0.1455 = 0.0291
        // Height bot exp = 0.2 * 0.2769 = 0.05538

        // newX = 0.4 - 0.038 = 0.362
        // newY = 0.4 - 0.0291 = 0.3709
        // newMaxX = 0.6 + 0.038 = 0.638
        // newMaxY = 0.6 + 0.05538 = 0.65538

        XCTAssertEqual(result.origin.x, 0.362, accuracy: 0.001)
        XCTAssertEqual(result.origin.y, 0.3709, accuracy: 0.001)
        XCTAssertEqual(result.width, 0.638 - 0.362, accuracy: 0.001)
        XCTAssertEqual(result.height, 0.65538 - 0.3709, accuracy: 0.001)
    }

    // MARK: - Clamping Tests

    func testClampingAtEdges() {
        // Input: Face at the very top-left edge (0,0)
        let faceRect = CGRect(x: 0.0, y: 0.0, width: 0.2, height: 0.2)
        let frameSize = CGSize(width: 100, height: 100)

        // Execute Upper Body (which tries to expand outwards)
        let result = ROICalculator.calculateROI(from: faceRect, method: "upper_body_cropped", frameSize: frameSize)

        // Check Left Edge
        // Ideally would expand to -0.038, should be clamped to 0.0
        XCTAssertEqual(result.origin.x, 0.0, accuracy: 0.0001)

        // Check Top Edge
        // Ideally would expand to -0.0291, should be clamped to 0.0
        XCTAssertEqual(result.origin.y, 0.0, accuracy: 0.0001)
    }

    func testClampingAtMaxEdges() {
        // Input: Face at the very bottom-right edge (0.8, 0.8) -> max is 1.0
        let faceRect = CGRect(x: 0.8, y: 0.8, width: 0.2, height: 0.2)
        let frameSize = CGSize(width: 100, height: 100)

        // Execute Upper Body (which tries to expand outwards)
        let result = ROICalculator.calculateROI(from: faceRect, method: "upper_body_cropped", frameSize: frameSize)

        // Check Right Edge (MaxX)
        // Ideally 1.0 + 0.038 = 1.038, clamped to 1.0
        XCTAssertEqual(result.maxX, 1.0, accuracy: 0.0001)

        // Check Bottom Edge (MaxY)
        // Ideally 1.0 + 0.055, clamped to 1.0
        XCTAssertEqual(result.maxY, 1.0, accuracy: 0.0001)
    }

    // MARK: - Validation Logic (Drift Check)

    func testFaceIsInsideROI() {
        // Setup: A fixed ROI (e.g., created by a previous face detection)
        // ROI: 0.3 to 0.7 (width 0.4)
        let fixedROI = CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4)

        // Case 1: Face is exactly in the center of ROI (Pass)
        // Face: 0.4 to 0.6 (width 0.2)
        let centeredFace = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertTrue(ROICalculator.isFace(centeredFace, sufficientlyInsideROI: fixedROI))

        // Case 2: Face moves slightly right (Pass)
        // Face: 0.45 to 0.65
        let slightMoveFace = CGRect(x: 0.45, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertTrue(ROICalculator.isFace(slightMoveFace, sufficientlyInsideROI: fixedROI))

        // Case 3: Face moves too far right (Fail)
        // Face: 0.55 to 0.75 (Right edge 0.75 is outside ROI 0.7)
        let farMoveFace = CGRect(x: 0.55, y: 0.4, width: 0.2, height: 0.2)
        XCTAssertFalse(ROICalculator.isFace(farMoveFace, sufficientlyInsideROI: fixedROI))

        // Case 4: Face is too large for ROI (Fail)
        // If the user moves closer to camera, face grows.
        // Face: 0.25 to 0.75 (width 0.5) -> Bigger than ROI width 0.4
        let largeFace = CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5)
        XCTAssertFalse(ROICalculator.isFace(largeFace, sufficientlyInsideROI: fixedROI))
    }
}