import XCTest

@testable import DexCore

/// A stale host found busy is waited on, and replaced once it isn't.
final class HostReplacementTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func welcomed(
        _ state: inout HostReplacement,
        pid: Int = 100,
        hostBuild: String? = "bbbbbbb",
        busy: Bool?,
        workSentAt: Date? = nil
    ) -> Bool {
        state.welcomed(
            pid: pid, appBuild: "aaaaaaa", hostBuild: hostBuild, sdk: nil,
            busy: busy, workSentAt: workSentAt
        )
    }

    func testStaleAndIdleReplacesAtOnce() {
        var state = HostReplacement()
        XCTAssertTrue(welcomed(&state, busy: false))
        XCTAssertFalse(state.isWaiting)
    }

    func testStaleAndBusyWaits() {
        var state = HostReplacement()
        XCTAssertFalse(welcomed(&state, busy: true))
        XCTAssertTrue(state.isWaiting)
    }

    /// A host too old to say whether it is busy is never stopped on a guess,
    /// and asking again won't make it say.
    func testAHostThatCantSayIsNotWaitedOn() {
        var state = HostReplacement()
        XCTAssertFalse(welcomed(&state, busy: nil))
        XCTAssertFalse(state.isWaiting)
    }

    func testACurrentHostIsNotWaitedOn() {
        var state = HostReplacement()
        XCTAssertFalse(welcomed(&state, hostBuild: "aaaaaaa", busy: true))
        XCTAssertFalse(state.isWaiting)
    }

    func testTheWaitEndsInAReplaceOnceTheHostSaysItIsIdle() {
        var state = HostReplacement()
        XCTAssertFalse(welcomed(&state, busy: true))
        state.asked(at: t0)
        XCTAssertTrue(welcomed(&state, busy: false))
        XCTAssertFalse(state.isWaiting)
    }

    /// The same pid again — the reconnect after the kill, a kill that didn't
    /// take — is never fired at twice.
    func testTheSamePidIsNotReplacedTwice() {
        var state = HostReplacement()
        XCTAssertTrue(welcomed(&state, busy: false))
        XCTAssertFalse(welcomed(&state, busy: false))
        XCTAssertFalse(welcomed(&state, busy: true))
        XCTAssertFalse(state.isWaiting)
    }

    /// The host that comes back with the signature just ended was respawned
    /// from a bundle that isn't this app's; waiting on it would end in the
    /// same kill loop.
    func testTheSameHostComingBackIsNeitherReplacedNorWaitedOn() {
        var state = HostReplacement()
        XCTAssertTrue(welcomed(&state, pid: 100, busy: false))
        XCTAssertFalse(welcomed(&state, pid: 101, busy: true))
        XCTAssertFalse(state.isWaiting)
        XCTAssertFalse(welcomed(&state, pid: 102, busy: false))
        XCTAssertTrue(welcomed(&state, pid: 103, hostBuild: "ccccccc", busy: false))
    }

    /// A send written behind the hello reached the host after its `busy` was
    /// taken, so an idle answer is out of date.
    func testWorkSentSinceAskingKeepsItWaiting() {
        var state = HostReplacement()
        XCTAssertFalse(welcomed(&state, busy: true))
        state.asked(at: t0)
        XCTAssertFalse(welcomed(&state, busy: false, workSentAt: t0.addingTimeInterval(0.01)))
        XCTAssertTrue(state.isWaiting)

        state.asked(at: t0.addingTimeInterval(60))
        XCTAssertTrue(welcomed(&state, busy: false, workSentAt: t0.addingTimeInterval(0.01)))
    }

    /// Work sent before an unasked welcome — the one on connecting — is
    /// already in its `busy`.
    func testWorkSentBeforeAnUnaskedWelcomeIsInItsReading() {
        var state = HostReplacement()
        XCTAssertTrue(welcomed(&state, busy: false, workSentAt: t0))
    }

    func testNothingIsAskedUnlessWaiting() {
        let state = HostReplacement()
        XCTAssertNil(state.nextAsk(holdsWork: false, lastMoved: t0))
    }

    func testNothingIsAskedWhileTheAppCanSeeWork() {
        var state = HostReplacement()
        _ = welcomed(&state, busy: true)
        XCTAssertNil(state.nextAsk(holdsWork: true, lastMoved: t0))
    }

    func testTheAskWaitsOutTheQuietAfterTheLastMove() {
        var state = HostReplacement()
        _ = welcomed(&state, busy: true)
        XCTAssertEqual(
            state.nextAsk(holdsWork: false, lastMoved: t0),
            t0.addingTimeInterval(HostReplacement.quiet)
        )
    }

    /// A host that still says busy while the app sees nothing — a send it has
    /// taken, a report the CLI owes a turn to — is asked again a quiet period
    /// later, not on every change.
    func testTheAskIsSpacedFromTheLastOne() {
        var state = HostReplacement()
        _ = welcomed(&state, busy: true)
        let later = t0.addingTimeInterval(100)
        state.asked(at: later)
        XCTAssertFalse(welcomed(&state, busy: true))
        XCTAssertEqual(
            state.nextAsk(holdsWork: false, lastMoved: t0),
            later.addingTimeInterval(HostReplacement.quiet)
        )
    }
}

extension HostReplacementTests {

    func testNothingIsCheckedUnlessWaiting() {
        XCTAssertNil(HostReplacement().nextCheck(holdsWork: true, lastMoved: t0, now: t0))
    }

    /// Work can end without the app hearing, a held login running out, so a
    /// wait always keeps a check pending.
    func testAWaitHeldByWorkStillLooksAgain() {
        var state = HostReplacement()
        _ = welcomed(&state, busy: true)
        XCTAssertEqual(
            state.nextCheck(holdsWork: true, lastMoved: t0, now: t0),
            t0.addingTimeInterval(HostReplacement.quiet)
        )
    }

    func testAnIdleWaitIsCheckedWhenTheAskIsDue() {
        var state = HostReplacement()
        _ = welcomed(&state, busy: true)
        let now = t0.addingTimeInterval(10)
        XCTAssertEqual(
            state.nextCheck(holdsWork: false, lastMoved: t0, now: now),
            t0.addingTimeInterval(HostReplacement.quiet)
        )
    }

    /// A sign-in or a login the host's `busy` can't show holds off every
    /// replace, the unasked welcome after a reconnect included.
    func testWorkOnlyTheAppKnowsOfHoldsOffAnyReplace() {
        var state = HostReplacement()
        XCTAssertFalse(state.welcomed(
            pid: 100, appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: false, appHoldsWork: true
        ))
        XCTAssertTrue(state.isWaiting)

        state.asked(at: t0)
        XCTAssertFalse(state.welcomed(
            pid: 100, appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: false, appHoldsWork: true
        ))
        XCTAssertTrue(state.isWaiting)

        XCTAssertTrue(state.welcomed(
            pid: 100, appBuild: "aaaaaaa", hostBuild: "bbbbbbb", sdk: nil, busy: false, appHoldsWork: false
        ))
    }
}
