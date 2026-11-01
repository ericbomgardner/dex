import XCTest

@testable import DexCore

private func ask(_ id: String, key: String = "s1") -> HostAsk {
    HostAsk(
        askId: id,
        key: key,
        kind: .permission,
        toolName: "Write",
        input: .object(["file_path": .string("/tmp/\(id).txt")]),
        options: [HostAskOption(optionId: "allow_once", name: "Allow", kind: .allowOnce)]
    )
}

final class HostAskQueueTests: XCTestCase {

    func testAnEmptyQueueHoldsNothing() {
        let queue = HostAskQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertTrue(queue.pending.isEmpty)
    }

    /// The order is the run the card pages through, so a second ask goes on the
    /// end rather than in front of one already being read.
    func testASecondAskGoesOnTheEnd() {
        var queue = HostAskQueue()
        queue.received(ask("a"))
        queue.received(ask("b"))

        XCTAssertEqual(queue.pending.map(\.askId), ["a", "b"])
    }

    func testTheSameAskArrivingTwiceIsHeldOnce() {
        var queue = HostAskQueue()
        queue.received(ask("a"))
        queue.received(ask("a"))
        XCTAssertEqual(queue.count, 1)
    }

    func testAnsweringTakesOneOutAndLeavesTheRestInOrder() {
        var queue = HostAskQueue()
        for id in ["a", "b", "c"] { queue.received(ask(id)) }

        queue.resolved("b")
        XCTAssertEqual(queue.pending.map(\.askId), ["a", "c"])
    }

    func testAWithdrawnAskLeavesTheQueueLikeAnAnsweredOne() {
        var queue = HostAskQueue()
        queue.received(ask("a"))
        XCTAssertTrue(queue.resolved("a"))
        XCTAssertFalse(queue.resolved("a"), "resolving twice is not an error, just nothing")
        XCTAssertTrue(queue.isEmpty)
    }

    func testASessionGoingAwayTakesOnlyItsOwnAsks() {
        var queue = HostAskQueue()
        queue.received(ask("a", key: "s1"))
        queue.received(ask("b", key: "s2"))
        queue.received(ask("c", key: "s1"))

        queue.dropAll(forKey: "s1")
        XCTAssertEqual(queue.pending.map(\.askId), ["b"])
    }

    /// The card is drawn per session, so what it asks for is one session's worth
    /// — another's question must not appear over this one's transcript.
    func testOneSessionsAsksComeBackWithoutTheOthers() {
        var queue = HostAskQueue()
        queue.received(ask("a", key: "s1"))
        queue.received(ask("b", key: "s2"))
        queue.received(ask("c", key: "s1"))

        XCTAssertEqual(queue.pending(forKey: "s1").map(\.askId), ["a", "c"])
        XCTAssertEqual(queue.pending(forKey: "s2").map(\.askId), ["b"])
        XCTAssertTrue(queue.pending(forKey: "gone").isEmpty)
    }
}
