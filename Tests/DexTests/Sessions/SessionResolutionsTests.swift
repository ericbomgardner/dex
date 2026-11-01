import XCTest
@testable import DexCore

final class SessionResolutionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func row(
        _ name: String,
        state: HostSessionState = .done,
        pid: Int? = nil,
        owesTurn: Bool = false,
        quietFor: TimeInterval? = nil,
        updatedHoursAgo: Double = 1,
        merge: WorktreeMergeStatus? = nil
    ) -> SessionRowModel {
        let updated = now.addingTimeInterval(-updatedHoursAgo * 3600)
        return SessionRowModel(
            session: makeSession(
                name,
                state: state,
                startedAt: updated.timeIntervalSince1970 * 1000,
                hostPID: pid
            ),
            lastActivityAt: quietFor.map { now.addingTimeInterval(-$0) },
            mergeStatus: merge,
            pinnedUpdate: updated,
            owesTurn: owesTurn
        )
    }

    /// Working by its transcript, stopped by the host's record, and quiet.
    private func staleWorking(_ name: String = "stale") -> SessionRowModel {
        row(name, state: .idle, pid: 1033, owesTurn: true, quietFor: 12 * 60)
    }

    private func resolved(_ rows: [SessionRowModel]) -> SessionResolutions {
        var marks = SessionResolutions()
        for row in rows { marks.resolve(row, at: now) }
        return marks
    }


    func testAnUnmarkedRowIsNeverSettled() {
        XCTAssertFalse(SessionResolutions().isSettled(row("a")))
    }

    func testMarkingARowSettlesIt() {
        let a = row("a")
        XCTAssertTrue(resolved([a]).isSettled(a))
    }

    func testClearingPutsARowBack() {
        let a = row("a")
        var marks = resolved([a])
        marks.clear(a)
        XCTAssertFalse(marks.isSettled(a))
    }

    func testResolveAndClearRoundTrip() {
        let a = row("a")
        var marks = SessionResolutions()
        marks.resolve(a, at: now)
        marks.clear(a)
        XCTAssertTrue(marks.isEmpty)
    }

    func testASessionThatDoesMoreWorkIsUnsettled() {
        let before = row("a", updatedHoursAgo: 2)
        var marks = SessionResolutions()
        marks.resolve(before, at: now.addingTimeInterval(-1800))
        XCTAssertTrue(marks.isSettled(before))

        let after = row("a", updatedHoursAgo: 0)
        XCTAssertFalse(marks.isSettled(after))
    }

    func testAMarkEqualToTheLastUpdateCounts() {
        let a = row("a", updatedHoursAgo: 0)
        var marks = SessionResolutions()
        marks.resolve(a, at: a.lastUpdatedAt)
        XCTAssertTrue(marks.isSettled(a))
    }

    func testARowUpdatedInTheFutureStillResolves() {
        let ahead = row("a", updatedHoursAgo: -0.001)
        XCTAssertTrue(resolved([ahead]).isSettled(ahead))
    }

    func testAFinishedSessionResolvesWhileItsProcessIsStillAround() {
        let lingering = row("a", state: .done, pid: 4321)
        XCTAssertTrue(resolved([lingering]).isSettled(lingering))
    }

    func testARowWaitingOnYouCanBeResolved() {
        let blocked = row("a", state: .asking)
        XCTAssertTrue(SessionResolutions().canResolve(blocked, now: now))
        XCTAssertTrue(resolved([blocked]).isSettled(blocked))
    }

    func testResolvingARowWaitingOnYouStopsItCountingAsWaiting() {
        let blocked = row("a", state: .asking)
        XCTAssertTrue(SessionResolutions().isWaitingOnYou(blocked))
        XCTAssertFalse(resolved([blocked]).isWaitingOnYou(blocked))
    }

    func testARowWaitingOnYouComesBackWhenTheAskChanges() {
        var marks = SessionResolutions()
        marks.resolve(row("a", state: .asking, updatedHoursAgo: 2), at: now.addingTimeInterval(-1800))

        let asksAgain = row("a", state: .asking, updatedHoursAgo: 0)
        XCTAssertFalse(marks.isSettled(asksAgain))
        XCTAssertTrue(marks.isWaitingOnYou(asksAgain))
    }

    func testAWorkingRowIsNotSettledWithoutAMark() {
        let working = row("a", state: .running)
        XCTAssertFalse(SessionResolutions().isSettled(working))
    }

    func testAStaleWorkingRowCanBeResolved() {
        let stale = staleWorking()
        XCTAssertTrue(stale.isIdleWhileWorking(now: now), "premise")
        XCTAssertTrue(SessionResolutions().canResolve(stale, now: now))

        var marks = SessionResolutions()
        marks.resolve(stale, at: now)
        XCTAssertTrue(marks.isSettled(stale))
    }

    func testTheTickIsNotOfferedWhileAProcessIsRunning() {
        let marks = SessionResolutions()
        let busy = row("a", state: .running, pid: 1, quietFor: 12 * 60)
        XCTAssertFalse(marks.canResolve(busy, now: now), "the host says it is running")
    }

    func testAResolvedStaleRowSurvivesItsProcessBeingReclaimed() {
        var marks = SessionResolutions()
        marks.resolve(staleWorking(), at: now)

        let reclaimed = row("stale", state: .idle)
        XCTAssertFalse(reclaimed.isIdleWhileWorking(now: now), "precondition: the signal is gone")
        XCTAssertTrue(marks.isSettled(reclaimed))
    }

    func testAResolvedStaleRowComesBackIfItStartsWorkingAgain() {
        var marks = SessionResolutions()
        marks.resolve(staleWorking(), at: now.addingTimeInterval(-1800))

        let resumed = row("stale", state: .running, pid: 1033, updatedHoursAgo: 0)
        XCTAssertFalse(marks.isSettled(resumed))
    }

    func testTheSweepLeavesRowsWaitingOnYouToTheTick() {
        let blocked = row("a", state: .asking)
        var marks = SessionResolutions()

        XCTAssertTrue(marks.resolvable(in: [blocked]).isEmpty)
        marks.resolveAll(in: [blocked], at: now)
        XCTAssertFalse(marks.isSettled(blocked), "a sweep must not resolve it")

        XCTAssertTrue(marks.canResolve(blocked, now: now), "the tick is still offered")
        marks.resolve(blocked, at: now)
        XCTAssertTrue(marks.isSettled(blocked))
    }

    func testFailedAndStoppedCanBeSettled() {
        for state in [HostSessionState.failed, .idle] {
            let r = row("a", state: state)
            XCTAssertTrue(resolved([r]).isSettled(r), "\(state) should be settleable")
        }
    }

    private func merge(
        _ state: BranchMergeState,
        dirty: Int? = 0,
        build: BuildInclusion? = nil
    ) -> WorktreeMergeStatus {
        WorktreeMergeStatus(base: "main", merge: state, uncommittedFiles: dirty, build: build)
    }

    func testOutstandingCommitsDoNotBlockTheClick() {
        let r = row("a", merge: merge(.outstanding(commits: 2)))
        XCTAssertTrue(SessionResolutions().canResolve(r))
        XCTAssertTrue(resolved([r]).isSettled(r))
    }

    func testUncommittedFilesDoNotBlockTheClick() {
        let r = row("a", merge: merge(.merged, dirty: 3))
        XCTAssertTrue(resolved([r]).isSettled(r))
    }

    func testLandedAloneDoesNotSettleARow() {
        let r = row("a", merge: merge(.merged))
        XCTAssertFalse(SessionResolutions().isSettled(r))
        XCTAssertTrue(resolved([r]).isSettled(r))
    }

    func testARowWithNoMergeStatusSettlesOnTheMarkAlone() {
        let r = row("a", merge: nil)
        XCTAssertTrue(resolved([r]).isSettled(r))
    }

    func testBranchGoneSettlesOnTheMarkAlone() {
        let r = row("a", merge: merge(.branchGone, dirty: nil))
        XCTAssertTrue(resolved([r]).isSettled(r))
    }

    func testTheTickIsOfferedOnEveryFinishedRow() {
        let marks = SessionResolutions()
        for status in [merge(.outstanding(commits: 2)), merge(.merged, dirty: 3),
                       merge(.merged), merge(.branchGone, dirty: nil)] {
            XCTAssertTrue(marks.canResolve(row("a", merge: status)), "\(status.label)")
        }
        XCTAssertTrue(marks.canResolve(row("a", merge: nil)))
    }

    func testTheTickIsNotOfferedOnWorkInFlight() {
        let marks = SessionResolutions()
        XCTAssertFalse(marks.canResolve(row("a", state: .running)))
        XCTAssertFalse(marks.canResolve(row("a", state: .unknown("quiesced"))))
    }

    func testASettledRowIsNotOfferedTheTickAgain() {
        let a = row("a")
        XCTAssertFalse(resolved([a]).canResolve(a))
    }

    func testBulkTakesFinishedUnvetoedRowsOnly() {
        let rows = [
            row("done"),
            row("blocked", state: .asking),
            row("working", state: .running),
            row("done-not-yet-reclaimed", pid: 99),
            row("orange", merge: merge(.outstanding(commits: 1))),
            row("landed", merge: merge(.merged)),
        ]
        let names = SessionResolutions().resolvable(in: rows).map(\.session.displayName)
        XCTAssertEqual(names, ["done", "done-not-yet-reclaimed", "landed"])
    }

    func testTheSweepSkipsWhatTheTickWillStillResolve() {
        let orange = row("orange", merge: merge(.outstanding(commits: 1)))
        var marks = SessionResolutions()

        XCTAssertTrue(marks.resolvable(in: [orange]).isEmpty)
        marks.resolveAll(in: [orange], at: now)
        XCTAssertFalse(marks.isSettled(orange), "a sweep must not resolve it")

        XCTAssertTrue(marks.canResolve(orange), "the tick is still offered")
        marks.resolve(orange, at: now)
        XCTAssertTrue(marks.isSettled(orange))
    }

    func testTheSweepLeavesWorkYouHaveNotRestartedInto() {
        let waiting = row("waiting", merge: merge(.merged, build: .awaitingRestart))
        var marks = SessionResolutions()

        XCTAssertTrue(
            marks.resolvable(in: [waiting]).isEmpty,
            "sweeping it away is how you'd never learn the app isn't running it"
        )
        marks.resolveAll(in: [waiting], at: now)
        XCTAssertFalse(marks.isSettled(waiting))

        XCTAssertTrue(marks.canResolve(waiting), "dismissing that one row is still yours to do")
    }

    func testTheSweepTakesWorkTheBuildIsAlreadyRunning() {
        let running = row("running", merge: merge(.merged, build: .inBuild))
        XCTAssertEqual(
            SessionResolutions().resolvable(in: [running]).map(\.session.displayName),
            ["running"]
        )
    }

    func testBulkSkipsRowsAlreadySettled() {
        let a = row("a")
        let b = row("b")
        var marks = SessionResolutions()
        marks.resolve(a, at: now)
        XCTAssertEqual(marks.resolvable(in: [a, b]).map(\.session.displayName), ["b"])
    }

    func testResolveAllSettlesEverythingItOffered() {
        let rows = [row("a"), row("b"), row("blocked", state: .asking)]
        var marks = SessionResolutions()
        marks.resolveAll(in: rows, at: now)
        XCTAssertEqual(marks.split(rows).settled.map(\.session.displayName), ["a", "b"])
        XCTAssertEqual(marks.split(rows).active.map(\.session.displayName), ["blocked"])
    }

    func testSplitPreservesOrderInBothHalves() {
        let rows = [row("a"), row("b"), row("c"), row("d")]
        var marks = SessionResolutions()
        marks.resolve(rows[1], at: now)
        marks.resolve(rows[3], at: now)
        let sections = marks.split(rows)
        XCTAssertEqual(sections.active.map(\.session.displayName), ["a", "c"])
        XCTAssertEqual(sections.settled.map(\.session.displayName), ["b", "d"])
    }

    func testSplitOfNothingIsEmpty() {
        let sections = SessionResolutions().split([])
        XCTAssertTrue(sections.active.isEmpty)
        XCTAssertTrue(sections.settled.isEmpty)
    }

    func testSplitLosesNoRows() {
        let rows = [
            row("done"), row("blocked", state: .asking), row("live", pid: 7),
            row("orange", merge: merge(.outstanding(commits: 1))),
            row("odd", state: .unknown("quiesced")), row("landed", merge: merge(.merged)),
        ]
        for marks in [SessionResolutions(), resolved(rows)] {
            let sections = marks.split(rows)
            XCTAssertEqual(
                Set((sections.active + sections.settled).map(\.rowID)),
                Set(rows.map(\.rowID))
            )
            XCTAssertEqual(sections.active.count + sections.settled.count, rows.count)
        }
    }

    func testAMarkForAMissingRowIsDroppedOnceItIsOld() {
        let old = row("gone", updatedHoursAgo: 30)
        var marks = SessionResolutions()
        marks.resolve(old, at: now.addingTimeInterval(-30 * 3600))
        marks.prune(keeping: [], now: now)
        XCTAssertTrue(marks.isEmpty)
    }

    func testARecentMarkSurvivesItsRowDisappearing() {
        let r = row("a", updatedHoursAgo: 1)
        var marks = resolved([r])
        marks.prune(keeping: [], now: now)
        XCTAssertTrue(marks.isSettled(r))
    }

    func testAnOldMarkSurvivesWhileItsRowIsStillListed() {
        let old = row("old", updatedHoursAgo: 40)
        var marks = SessionResolutions()
        marks.resolve(old, at: now.addingTimeInterval(-40 * 3600))
        marks.prune(keeping: [old.rowID], now: now)
        XCTAssertFalse(marks.isEmpty)
    }

    func testMarksRoundTripThroughJSON() throws {
        let marks = resolved([row("a"), row("b")])
        let data = try JSONEncoder().encode(marks)
        let back = try JSONDecoder().decode(SessionResolutions.self, from: data)
        XCTAssertEqual(back, marks)
    }
}
