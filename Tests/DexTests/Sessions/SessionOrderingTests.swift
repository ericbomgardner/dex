import XCTest
@testable import DexCore

final class OrderingTests: XCTestCase {
    func testBlockedSortsFirstThenWorking() {
        let rows = [
            makeRow("done", state: .done),
            makeRow("working", state: .running),
            makeRow("blocked", state: .asking),
            makeRow("failed", state: .failed),
        ]
        XCTAssertEqual(
            SessionOrdering.sorted(rows).map(\.session.displayName),
            ["blocked", "working", "failed", "done"]
        )
    }

    func testEveryStateOfATurnInFlightSortsAsWorking() {
        let rows = [
            makeRow("done", state: .done, startedAt: 9_000),
            makeRow("newer-host", state: .unknown("hibernating"), startedAt: 1_000),
            makeRow("compacting", state: .compacting, startedAt: 2_000),
            makeRow("starting", state: .starting, startedAt: 3_000),
            makeRow("idle", state: .idle, startedAt: 8_000),
        ]
        XCTAssertEqual(
            SessionOrdering.sorted(rows).map(\.session.displayName),
            ["starting", "compacting", "newer-host", "done", "idle"]
        )
    }

    func testNewestFirstWithinABucket() {
        let rows = [
            makeRow("older", state: .asking, startedAt: 1_000),
            makeRow("newer", state: .asking, startedAt: 9_000),
        ]
        XCTAssertEqual(SessionOrdering.sorted(rows).map(\.session.displayName), ["newer", "older"])
    }

    func testLastUpdateTakesPrecedenceOverStartTime() {
        let rows = [

            makeRow("stale", state: .done, startedAt: 9_000,
                    pinnedUpdate: Date(timeIntervalSince1970: 9.5)),

            makeRow("just-replied", state: .done, startedAt: 1_000,
                    pinnedUpdate: Date(timeIntervalSince1970: 50)),
        ]
        XCTAssertEqual(
            SessionOrdering.sorted(rows).map(\.session.displayName),
            ["just-replied", "stale"]
        )
    }

    func testLastUpdateOrdersBlockedAndWorkingToo() {
        let rows = [
            makeRow("asked-first", state: .asking, startedAt: 1_000,
                    pinnedUpdate: Date(timeIntervalSince1970: 2)),
            makeRow("asked-just-now", state: .asking, startedAt: 500,
                    pinnedUpdate: Date(timeIntervalSince1970: 90)),
            makeRow("quiet-worker", state: .running, startedAt: 1_000,
                    pinnedUpdate: Date(timeIntervalSince1970: 1.1)),
            makeRow("busy-worker", state: .running, startedAt: 900,
                    pinnedUpdate: Date(timeIntervalSince1970: 80)),
        ]
        XCTAssertEqual(
            SessionOrdering.sorted(rows).map(\.session.displayName),
            ["asked-just-now", "asked-first", "busy-worker", "quiet-worker"]
        )
    }

    func testFallsBackToStartTimeWithoutAPin() {
        let rows = [
            makeRow("unpinned-old", state: .idle, startedAt: 1_000),
            makeRow("unpinned-new", state: .idle, startedAt: 9_000),
        ]
        XCTAssertEqual(
            SessionOrdering.sorted(rows).map(\.session.displayName),
            ["unpinned-new", "unpinned-old"]
        )
    }

    func testBlockedCountDrivesTheMenuBarNumber() {
        let rows = [
            makeRow("a", state: .asking),
            makeRow("b", state: .asking),
            makeRow("c", state: .running),
            makeRow("d", state: .unknown("hibernating")),
        ]
        XCTAssertEqual(SessionOrdering.blockedCount(rows), 2)
    }

    func testResolvingARowDropsItOutOfItsStateBucket() {
        let rows = [
            makeRow("resolved-ask", state: .asking, startedAt: 9_000),
            makeRow("still-asking", state: .asking, startedAt: 1_000),
            makeRow("done", state: .done, startedAt: 2_000),
        ]
        var marks = SessionResolutions()
        marks.resolve(rows[0], at: rows[0].lastUpdatedAt)

        XCTAssertEqual(
            SessionOrdering.sorted(rows, resolutions: marks).map(\.session.displayName),
            ["still-asking", "done", "resolved-ask"]
        )
    }

    func testResolvedRowsSortByRecencyAmongThemselves() {
        let rows = [
            makeRow("older-ask", state: .asking, startedAt: 1_000),
            makeRow("newer-finish", state: .done, startedAt: 9_000),
        ]
        var marks = SessionResolutions()
        for row in rows { marks.resolve(row, at: row.lastUpdatedAt) }

        XCTAssertEqual(
            SessionOrdering.sorted(rows, resolutions: marks).map(\.session.displayName),
            ["newer-finish", "older-ask"]
        )
    }

    // A dispatch shows up in the list before the CLI knows about it, and the row
    // it turns into sorts as a working session. Both have to be in the same
    // place or the row jumps the moment it becomes real.

    /// A dispatch is named for what was typed at it, since every one of them
    /// wears the same title until the session it starts has a name of its own.
    private func names(_ items: [SessionListItem]) -> [String] {
        items.map { item in
            switch item {
            case .starting(let dispatch): dispatch.opening ?? dispatch.title
            case .session(let row): row.session.displayName
            }
        }
    }

    private func starting(_ prompt: String, at seconds: TimeInterval) -> PendingDispatch {
        PendingDispatch(prompt: prompt, project: "/p/alpha",
                        startedAt: Date(timeIntervalSince1970: seconds), knownRowIDs: [])
    }

    func testStartingSessionsSortWhereTheirRowWill() {
        let rows = SessionOrdering.sorted([
            makeRow("waiting", state: .asking),
            makeRow("busy", state: .running),
            makeRow("done", state: .done),
        ])

        XCTAssertEqual(
            names(SessionOrdering.merged(rows, starting: [starting("new one", at: 9_000)])),
            ["waiting", "new one", "busy", "done"]
        )
    }

    func testStartingSessionsSortNewestFirstAmongThemselves() {
        let items = SessionOrdering.merged(
            [],
            starting: [starting("older", at: 1_000), starting("newer", at: 9_000)]
        )
        XCTAssertEqual(names(items), ["newer", "older"])
    }

    func testStartingSessionsGoFirstWithNothingWaitingOnYou() {
        let rows = SessionOrdering.sorted([makeRow("busy", state: .running)])
        XCTAssertEqual(
            names(SessionOrdering.merged(rows, starting: [starting("new one", at: 9_000)])),
            ["new one", "busy"]
        )
    }

    func testStartingSessionsGoLastWhenEverythingIsWaitingOnYou() {
        let rows = SessionOrdering.sorted([
            makeRow("waiting", state: .asking),
            makeRow("also-waiting", state: .asking),
        ])
        XCTAssertEqual(
            names(SessionOrdering.merged(rows, starting: [starting("new one", at: 9_000)])).last,
            "new one"
        )
    }

    /// A resolved row is out of its state's bucket, so a blocked one that has
    /// been ticked off doesn't push a starting session down past it.
    func testResolvedBlockedRowsDontHoldStartingSessionsDown() {
        let rows = [makeRow("resolved-ask", state: .asking, startedAt: 9_000)]
        var marks = SessionResolutions()
        marks.resolve(rows[0], at: rows[0].lastUpdatedAt)

        let items = SessionOrdering.merged(
            SessionOrdering.sorted(rows, resolutions: marks),
            starting: [starting("new one", at: 1_000)],
            resolutions: marks
        )
        XCTAssertEqual(names(items), ["new one", "resolved-ask"])
    }

    func testMergingKeepsEveryRowWithNothingStarting() {
        let rows = SessionOrdering.sorted([
            makeRow("waiting", state: .asking),
            makeRow("busy", state: .running),
        ])
        XCTAssertEqual(names(SessionOrdering.merged(rows, starting: [])), ["waiting", "busy"])
    }

    func testOrderingIsTotalAndKeepsEveryRow() {
        let rows = [
            makeRow("i", state: .starting),
            makeRow("u", state: .unknown("weird")),
            makeRow("s", state: .idle),
            makeRow("b", state: .asking),
        ]
        XCTAssertEqual(SessionOrdering.sorted(rows).count, rows.count)
    }
}
