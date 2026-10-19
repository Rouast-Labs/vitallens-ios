import XCTest
@testable import VitalLensUI

final class HrvGatingTests: XCTestCase {

    func testShowsHrvWhenBothAreConfident() {
        XCTAssertTrue(isHrvShown(hrvConf: 0.85, hrConf: 0.9, hrvThreshold: 0.8, hrThreshold: 0.8))
    }

    func testHidesHrvWhenHeartRateIsNotConfident() {
        XCTAssertFalse(isHrvShown(hrvConf: 0.95, hrConf: 0.79, hrvThreshold: 0.8, hrThreshold: 0.8))
    }

    func testHidesHrvWhenHrvIsNotConfident() {
        XCTAssertFalse(isHrvShown(hrvConf: 0.79, hrConf: 0.95, hrvThreshold: 0.8, hrThreshold: 0.8))
    }

    func testThresholdIsInclusive() {
        XCTAssertTrue(isHrvShown(hrvConf: 0.8, hrConf: 0.8, hrvThreshold: 0.8, hrThreshold: 0.8))
    }

    func testHidesHrvWhenConfidencesAreMissing() {
        XCTAssertFalse(isHrvShown(hrvConf: nil, hrConf: 0.9, hrvThreshold: 0.8, hrThreshold: 0.8))
        XCTAssertFalse(isHrvShown(hrvConf: 0.9, hrConf: nil, hrvThreshold: 0.8, hrThreshold: 0.8))
    }
}
