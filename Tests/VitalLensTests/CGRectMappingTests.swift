import XCTest
import ImageIO
@testable import VitalLens

final class CGRectMappingTests: XCTestCase {
    
    // We use a quadrant test ROI: Top-Right corner (x: 0.5, y: 0.0, width: 0.5, height: 0.5)
    let uprightROI = CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5)

    func testMapping_Up_Unmirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .up, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5))
    }

    func testMapping_Up_Mirrored() {
        // Mirrored horizontally: Top-Right becomes Top-Left
        let raw = uprightROI.mappedToRaw(orientation: .up, isMirrored: true)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5))
    }

    func testMapping_Left_Unmirrored() {
        // .left means the camera was rotated 90 degrees CCW (Landscape Right).
        // To get back to the raw buffer, we rotate 90 degrees CW.
        // Top-Right rotates to Bottom-Right.
        let raw = uprightROI.mappedToRaw(orientation: .left, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testMapping_Right_Unmirrored() {
        // .right means the camera was rotated 90 degrees CW (Landscape Left).
        // To get back to the raw buffer, we rotate 90 degrees CCW.
        // Top-Right rotates to Top-Left.
        let raw = uprightROI.mappedToRaw(orientation: .right, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5))
    }

    func testMapping_Down_Unmirrored() {
        // .down means the camera was upside down.
        // Top-Right rotates 180 degrees to Bottom-Left.
        let raw = uprightROI.mappedToRaw(orientation: .down, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5))
    }
    
    func testMapping_Right_Mirrored() {
        // .rightMirrored (Front camera, Landscape Left)
        // 1. Un-mirror (Top-Right -> Top-Left)
        // 2. Un-rotate 90 CCW (Top-Left -> Bottom-Left)
        let raw = uprightROI.mappedToRaw(orientation: .rightMirrored, isMirrored: true)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5))
    }
}