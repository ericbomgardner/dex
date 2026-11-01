import XCTest

@testable import DexCore

@testable import DexUI

/// What the app has the host doing that neither the host's sessions nor its
/// `busy` show, which holds off replacing a stale one.
@MainActor
final class HostWorkInFlightTests: XCTestCase {

    func testWorkInFlightHoldsUntilItEnds() {
        let host = HostSessions()
        var heard = 0
        host.onWork = { heard += 1 }
        XCTAssertFalse(host.holdsWork())

        host.beginWork()
        host.beginWork()
        XCTAssertTrue(host.holdsWork())
        host.endWork()
        XCTAssertTrue(host.holdsWork())
        host.endWork()
        XCTAssertFalse(host.holdsWork())
        XCTAssertEqual(heard, 4)
    }

    /// The quiet period runs from when work ended, not when it began.
    func testEndingWorkMovesTheClock() {
        let host = HostSessions()
        host.beginWork()
        let began = host.lastWorkSent
        host.endWork()
        XCTAssertNotNil(began)
        XCTAssertGreaterThanOrEqual(host.lastWorkSent ?? .distantPast, began ?? .distantFuture)
        XCTAssertEqual(host.lastMoved, host.lastWorkSent)
    }

    func testAnUnbalancedEndDoesNotGoNegative() {
        let host = HostSessions()
        host.endWork()
        host.beginWork()
        XCTAssertTrue(host.holdsWork())
    }

    /// An MCP login is finished in the browser, with no answer to wait for.
    func testAHoldLastsUntilItsDeadline() {
        let host = HostSessions()
        host.hold("mcp-login s1 linear", for: 300)
        XCTAssertTrue(host.holdsWork())
        XCTAssertTrue(host.holdsWork(now: Date().addingTimeInterval(299)))
        XCTAssertFalse(host.holdsWork(now: Date().addingTimeInterval(301)))
    }

    /// A dropped socket answers the waiter but leaves the login running on
    /// the host, so the work is held rather than ended.
    func testWorkCutOffByADropIsHeld() {
        let host = HostSessions()
        host.beginWork()
        let dropped = HostReply(id: "r1", ok: false, key: nil, error: HostClient.droppedError)
        host.endWork(after: dropped, holding: "mcp-login", for: 300)
        XCTAssertTrue(host.holdsWork())
        XCTAssertFalse(host.holdsWork(now: Date().addingTimeInterval(301)))
    }

    func testWorkTheHostAnsweredEnds() {
        let host = HostSessions()
        host.beginWork()
        let refused = HostReply(id: "r1", ok: false, key: nil, error: "no")
        host.endWork(after: refused, holding: "mcp-login", for: 300)
        XCTAssertFalse(host.holdsWork())
    }
}
