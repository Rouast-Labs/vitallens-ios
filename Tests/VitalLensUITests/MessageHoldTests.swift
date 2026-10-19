import XCTest
@testable import VitalLensUI

/// A manual clock and scheduler, so that the hold logic is tested without real waiting.
@MainActor
private final class FakeClock {
    var time: TimeInterval = 0
    private var scheduled: [(id: Int, at: TimeInterval, action: @MainActor () -> Void)] = []
    private var nextId = 0
    
    func schedule(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) -> () -> Void {
        let id = nextId
        nextId += 1
        scheduled.append((id, time + delay, action))
        return { [weak self] in self?.scheduled.removeAll { $0.id == id } }
    }
    
    func advance(_ seconds: TimeInterval) {
        let target = time + seconds
        while let next = scheduled.filter({ $0.at <= target }).min(by: { $0.at < $1.at }) {
            time = next.at
            scheduled.removeAll { $0.id == next.id }
            next.action()
        }
        time = target
    }
}

@MainActor
final class MessageHoldTests: XCTestCase {
    private var clock: FakeClock!
    private var shown: [String]!
    private var forced: [Bool]!
    private var hold: MessageHold!
    
    override func setUp() async throws {
        clock = FakeClock()
        shown = []
        forced = []
        hold = MessageHold(
            minInterval: 3,
            now: { [clock] in clock!.time },
            schedule: { [clock] delay, action in clock!.schedule(delay, action) },
            apply: { [weak self] text, force in
                self?.shown.append(text)
                self?.forced.append(force)
            }
        )
    }
    
    func testShowsMessagesImmediatelyWhenNothingIsHeld() {
        hold.show("a")
        hold.show("b")
        XCTAssertEqual(shown, ["a", "b"])
    }
    
    func testAHeldMessageIsNotReplacedBeforeTheMinimumTime() {
        hold.show("Low confidence", hold: true)
        clock.advance(0.5)
        hold.show("Scanning")
        XCTAssertEqual(shown, ["Low confidence"])
        clock.advance(2.4)
        XCTAssertEqual(shown, ["Low confidence"])
        clock.advance(0.2)
        XCTAssertEqual(shown, ["Low confidence", "Scanning"])
    }
    
    func testOnlyTheLatestWaitingMessageIsShown() {
        hold.show("Low confidence", hold: true)
        hold.show("b")
        hold.show("c")
        clock.advance(3.001)
        XCTAssertEqual(shown, ["Low confidence", "c"])
    }
    
    func testAWaitingMessageThatEqualsTheHeldOneIsDropped() {
        hold.show("Low confidence", hold: true)
        hold.show("Scanning")
        hold.show("Low confidence", hold: true)
        clock.advance(3.001)
        XCTAssertEqual(shown, ["Low confidence"])
    }
    
    func testReShowingTheHeldMessageDoesNotExtendTheHold() {
        hold.show("Low confidence", hold: true)
        clock.advance(2)
        hold.show("Low confidence", hold: true)
        clock.advance(1.1)
        hold.show("Scanning")
        XCTAssertEqual(shown.last, "Scanning")
    }
    
    func testAWaitingHeldMessageGetsItsOwnFullHold() {
        hold.show("A", hold: true)
        hold.show("B", hold: true)
        clock.advance(3.001)
        XCTAssertEqual(shown, ["A", "B"])
        hold.show("C")
        XCTAssertEqual(shown, ["A", "B"])
        clock.advance(3.001)
        XCTAssertEqual(shown, ["A", "B", "C"])
    }
    
    func testImmediateDropsTheHoldAndTheWaitingMessage() {
        hold.show("Low confidence", hold: true)
        hold.show("Scanning")
        hold.show("Issue", immediate: true)
        clock.advance(5)
        XCTAssertEqual(shown, ["Low confidence", "Issue"])
    }
    
    func testReleaseLetsTheNextMessageThrough() {
        hold.show("Low confidence", hold: true)
        hold.release()
        hold.show("Scanning")
        XCTAssertEqual(shown, ["Low confidence", "Scanning"])
    }
    
    func testForceIsPassedThroughAlsoForWaitingMessages() {
        hold.show("A", hold: true)
        hold.show("B", force: true)
        clock.advance(3.001)
        XCTAssertEqual(shown, ["A", "B"])
        XCTAssertEqual(forced, [false, true])
    }
}
