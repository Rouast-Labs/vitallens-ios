import XCTest
import ImageIO
@testable import VitalLens

final class CGRectMappingTests: XCTestCase {
    
    let uprightROI = CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5)

    func testMapping_Up_Unmirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .up, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.5, y: 0.0, width: 0.5, height: 0.5))
    }

    func testMapping_Up_Mirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .up, isMirrored: true)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5))
    }

    func testMapping_Left_Unmirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .left, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
    }

    func testMapping_Right_Unmirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .right, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.0, width: 0.5, height: 0.5))
    }

    func testMapping_Down_Unmirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .down, isMirrored: false)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5))
    }
    
    func testMapping_Right_Mirrored() {
        let raw = uprightROI.mappedToRaw(orientation: .rightMirrored, isMirrored: true)
        XCTAssertEqual(raw, CGRect(x: 0.0, y: 0.5, width: 0.5, height: 0.5))
    }
}