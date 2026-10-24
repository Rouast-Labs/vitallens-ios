import XCTest
@testable import VitalLensInference

final class VitalLensVersionTests: XCTestCase {

    func testCurrentIsSemanticVersion() {
        let parts = VitalLensVersion.current.split(separator: ".")
        XCTAssertEqual(parts.count, 3)
        XCTAssertTrue(parts.allSatisfy { Int($0) != nil })
    }

    func testApiOriginIsClientNameWithVersion() {
        XCTAssertEqual(VitalLensVersion.apiOrigin, "vitallens-ios_\(VitalLensVersion.current)")
    }

    func testApiOriginIsAcceptedByTheAPI() {
        // Same pattern as the /file request model: a short label of letters, digits and . _ + -
        let pattern = "^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"
        XCTAssertNotNil(VitalLensVersion.apiOrigin.range(of: pattern, options: .regularExpression))
    }
}
