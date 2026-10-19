import XCTest
@testable import VitalLensInference

final class ConnectionMonitorTests: XCTestCase {

    private func makeMonitor() -> ConnectionMonitor {
        ConnectionMonitor(medianMs: 1000, singleMs: 2000, maxFrames: 50, window: 5, minSamples: 3)
    }

    func testDoesNotFireWhileTheConnectionIsFast() {
        var monitor = makeMonitor()
        for _ in 0..<20 {
            XCTAssertNil(monitor.record(ms: 250, frames: 8))
        }
    }

    func testFiresWhenTheMedianExceedsTheLimit() {
        var monitor = makeMonitor()
        XCTAssertNil(monitor.record(ms: 1500, frames: 10))
        XCTAssertNil(monitor.record(ms: 1200, frames: 10), "not enough samples yet")
        let info = monitor.record(ms: 1100, frames: 10)
        XCTAssertEqual(info, SlowConnectionInfo(medianMs: 1200, frames: 10))
    }

    func testIgnoresASingleModeratelySlowRequest() {
        var monitor = makeMonitor()
        for ms in [250.0, 300, 1900, 260, 240] {
            XCTAssertNil(monitor.record(ms: ms, frames: 8))
        }
    }

    func testFiresOnTheFirstRequestIfItIsVerySlow() {
        var monitor = makeMonitor()
        XCTAssertEqual(
            monitor.record(ms: 3110, frames: 16),
            SlowConnectionInfo(medianMs: 3110, frames: 16)
        )
    }

    func testFiresOnTheFirstRequestIfItCarriesTooManyFrames() {
        var monitor = makeMonitor()
        XCTAssertNotNil(monitor.record(ms: 300, frames: 60))
    }

    func testOnlyConsidersTheMostRecentRequests() {
        var monitor = makeMonitor()
        for _ in 0..<5 { XCTAssertNil(monitor.record(ms: 300, frames: 8)) }
        XCTAssertNil(monitor.record(ms: 1500, frames: 8))
        XCTAssertNil(monitor.record(ms: 1500, frames: 8)) // window median is still 300
        XCTAssertNotNil(monitor.record(ms: 1500, frames: 8)) // 300, 300, 1500, 1500, 1500
    }

    func testFiresOnlyOnce() {
        var monitor = makeMonitor()
        XCTAssertNotNil(monitor.record(ms: 3000, frames: 8))
        for _ in 0..<10 { XCTAssertNil(monitor.record(ms: 3000, frames: 8)) }
    }

    func testCanBeResetToStartOver() {
        var monitor = makeMonitor()
        XCTAssertNotNil(monitor.record(ms: 3000, frames: 8))
        monitor.reset()
        XCTAssertNotNil(monitor.record(ms: 3000, frames: 8))
    }
}
