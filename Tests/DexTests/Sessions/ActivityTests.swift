import XCTest
@testable import DexCore

final class ActivitySignalTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    /// A state from a newer host is read as work, like the rest of these.
    func testATurnTheHostSaysIsRunningIsActiveEvenWithAColdTranscript() {
        for state in [HostSessionState.starting, .running, .compacting, .unknown("hibernating")] {
            XCTAssertEqual(
                ActivitySignal.resolve(state: state, lastTranscriptWrite: at(600), now: now),
                .active,
                state.raw
            )
        }
    }

    func testAskingIsUnknownSoAskingRowsAreNotDimmed() {

        XCTAssertEqual(
            ActivitySignal.resolve(state: .asking, lastTranscriptWrite: at(600), now: now),
            .unknown
        )
    }

    func testAStoppedTurnIsReadOffTheTranscriptClock() {
        for state in [HostSessionState.idle, .done, .failed] {
            XCTAssertEqual(
                ActivitySignal.resolve(state: state, lastTranscriptWrite: at(2), now: now),
                .active,
                state.raw
            )
            XCTAssertEqual(
                ActivitySignal.resolve(state: state, lastTranscriptWrite: at(1_200), now: now),
                .quiet,
                state.raw
            )
        }
    }

    func testIdleJustUnderTheThresholdIsActive() {
        XCTAssertEqual(
            ActivitySignal.resolve(
                state: .idle,
                lastTranscriptWrite: at(ActivitySignal.quietAfter - 0.5),
                now: now
            ),
            .active
        )
    }

    func testIdleAtThresholdIsQuiet() {
        XCTAssertEqual(
            ActivitySignal.resolve(
                state: .idle,
                lastTranscriptWrite: at(ActivitySignal.quietAfter),
                now: now
            ),
            .quiet
        )
    }

    func testIdleWithNoTranscriptIsUnknownNotQuiet() {

        XCTAssertEqual(
            ActivitySignal.resolve(state: .idle, lastTranscriptWrite: nil, now: now),
            .unknown
        )
    }

    func testFutureMtimeIsUnknownNotQuiet() {

        XCTAssertEqual(
            ActivitySignal.resolve(state: .idle, lastTranscriptWrite: at(-30), now: now),
            .unknown
        )
    }

    func testOnlyQuietAllowsDimming() {
        XCTAssertTrue(Activity.quiet.isQuiet)
        XCTAssertFalse(Activity.active.isQuiet)
        XCTAssertFalse(Activity.unknown.isQuiet)
    }
}

/// A row the host says is running is active by definition, so the rows that
/// can go quiet while working are the ones the transcript says are: a turn
/// owed by a session the host still has as stopped.
final class IdleWhileWorkingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    private func owed(_ name: String, lastActivityAt: Date? = nil, hostedSummary: String? = nil)
        -> SessionRowModel
    {
        makeRow(name, state: .idle, hostPID: 74_447, lastActivityAt: lastActivityAt,
                owesTurn: true, hostedSummary: hostedSummary)
    }

    func testAStaleOwedTurnIsDimmed() {
        XCTAssertTrue(owed("worktree", lastActivityAt: at(1_200)).isIdleWhileWorking(now: now))
    }

    func testARunningSessionIsNeverDimmed() {
        let row = makeRow("live", state: .running, hostPID: 84_944, lastActivityAt: at(1_200))
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
    }

    func testAPauseBetweenToolCallsIsNotDimmed() {
        XCTAssertFalse(owed("pausing", lastActivityAt: at(3)).isIdleWhileWorking(now: now))
    }

    func testAskingIsNeverDimmed() {

        let row = makeRow("asking", state: .asking, hostPID: 69_696,
                          lastActivityAt: at(3_600), owesTurn: true)
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
        XCTAssertEqual(row.activity(now: now), .unknown)
    }

    func testFinishedSessionsAreNotDimmed() {

        for state in [HostSessionState.done, .failed, .idle] {
            let row = makeRow("t", state: state, hostPID: 1, lastActivityAt: at(3_600))
            XCTAssertFalse(row.isIdleWhileWorking(now: now), "\(state.raw) should not dim")
        }
    }

    func testAStateFromANewerHostIsNotDimmed() {

        let row = makeRow("drift", state: .unknown("hibernating"), hostPID: 1,
                          lastActivityAt: at(3_600))
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
    }

    func testARowWithNoTranscriptIsUnchanged() {
        let row = owed("noTranscript")
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
        XCTAssertEqual(row.activity(now: now), .unknown)
    }

    /// The host emits on state changes, and a turn runs from its first tool call
    /// to its last without changing state — so a transcript write is the only
    /// thing that can move a row's second line while a turn is going.
    func testRefreshedTakesANewerHostedLine() {
        let row = SessionRowModel(
            hosted: hostSummary(state: .running),
            hostPID: 42,
            digest: SessionDigest(lastMessage: "Reading the pending dispatch machinery")
        )
        let fresh = row.refreshed(
            activityAt: at(1),
            hostedSummary: "Run the full suite after the review fixes"
        )
        XCTAssertEqual(fresh.summary, "Run the full suite after the review fixes")
    }

    /// A refresh that read nothing keeps what the row had, rather than blanking
    /// the line back to the session's own path.
    func testRefreshedKeepsTheHostedLineWhenNothingWasRead() {
        let row = SessionRowModel(
            hosted: hostSummary(state: .running),
            hostPID: 42,
            digest: SessionDigest(lastMessage: "Reading the pending dispatch machinery")
        )
        let fresh = row.refreshed(activityAt: at(1))
        XCTAssertEqual(fresh.summary, "Reading the pending dispatch machinery")
    }

    private func hostSummary(state: HostSessionState) -> HostSessionSummary {
        HostSessionSummary(
            key: "k1",
            sessionId: "uuid-1",
            cwd: "/tmp/work",
            name: nil,
            state: state,
            model: nil,
            permissionMode: "default",
            startedAt: "2026-08-11T00:00:00Z"
        )
    }
    func testRefreshedLeavesTheSessionFieldsUnchanged() {

        let row = makeRow("live", state: .running, hostPID: 1, hostedSummary: "old")
        let fresh = row.refreshed(activityAt: at(1), hostedSummary: "new")

        XCTAssertEqual(fresh.session.state, .running)
        XCTAssertEqual(fresh.session.hostPID, 1)
        XCTAssertEqual(fresh.rowID, row.rowID)
    }

    func testRefreshedKeepsTheActivityTimestampWhenOnlyTheLineMoved() {
        let row = owed("live", lastActivityAt: at(1_200))
        let fresh = row.refreshed(activityAt: nil, hostedSummary: "new")

        XCTAssertEqual(fresh.lastActivityAt, at(1_200))
        XCTAssertTrue(fresh.isIdleWhileWorking(now: now), "a line read is not evidence of activity")
    }

    func testWithActivityReplacesOnlyTheTimestamp() {
        let row = owed("push", lastActivityAt: at(1_200), hostedSummary: "building")
        XCTAssertTrue(row.isIdleWhileWorking(now: now))

        let pushed = row.refreshed(activityAt: at(1))
        XCTAssertFalse(pushed.isIdleWhileWorking(now: now))
        XCTAssertEqual(pushed.summary, "building")
        XCTAssertEqual(pushed.rowID, row.rowID)
    }
}

final class ActivelyWorkingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func at(_ secondsAgo: TimeInterval) -> Date {
        now.addingTimeInterval(-secondsAgo)
    }

    func testARunningSessionSpinsHoweverQuietItsFile() {
        let row = makeRow("live", state: .running, hostPID: 84_944, lastActivityAt: at(1_200))
        XCTAssertTrue(row.isActivelyWorking(now: now))
        XCTAssertTrue(row.session.isLive)
    }

    func testAPauseBetweenToolCallsKeepsSpinning() {

        let row = makeRow("pausing", state: .idle, hostPID: 84_944,
                          lastActivityAt: at(3), owesTurn: true)
        XCTAssertTrue(row.isActivelyWorking(now: now))
    }

    func testAStaleOwedTurnDoesNotSpin() {

        let row = makeRow("worktree", state: .idle, hostPID: 74_447,
                          lastActivityAt: at(1_200), owesTurn: true)
        XCTAssertFalse(row.isActivelyWorking(now: now))
        XCTAssertTrue(row.isIdleWhileWorking(now: now))
    }

    func testDimmingAndSpinningAreIndependent() {

        let row = makeRow("noTranscript", state: .idle, hostPID: 1, owesTurn: true)
        XCTAssertEqual(row.activity(now: now), .unknown)
        XCTAssertFalse(row.isActivelyWorking(now: now))
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
    }

    func testAStoppedOrAskingSessionDoesNotSpin() {

        for state in [HostSessionState.asking, .done, .failed, .idle] {
            let row = makeRow("t", state: state, hostPID: 1, lastActivityAt: at(1))
            XCTAssertFalse(row.isActivelyWorking(now: now), "\(state.raw) should not spin")
        }
    }

    /// The gap this is all for: the message you just sent is in the transcript,
    /// and the host's record of the session still says the turn it finished.
    func testATurnTheRecordHasntCaughtUpWithSpins() {
        let row = makeRow("sent", state: .done, hostPID: 84_944,
                          lastActivityAt: at(1), owesTurn: true)
        XCTAssertTrue(row.isWorking)
        XCTAssertTrue(row.isActivelyWorking(now: now))
    }

    /// And it goes quiet the way a recorded working row does — a session that
    /// died mid-turn leaves the file owed forever, and nothing else would ever
    /// take the spinner off it.
    func testATurnOwedByASessionThatWentQuietStopsSpinning() {
        let row = makeRow("gone", state: .done, hostPID: 84_944,
                          lastActivityAt: at(1_200), owesTurn: true)
        XCTAssertFalse(row.isActivelyWorking(now: now))
        XCTAssertTrue(row.isIdleWhileWorking(now: now))
    }

    /// Asking is the session holding out for you. The transcript reads the same
    /// either way — a question is a call nothing has come back to — so the answer
    /// has to come from the record, which knows.
    func testAQuestionOwesATurnButIsNotWorking() {
        let row = makeRow("asking", state: .asking, hostPID: 84_944,
                          lastActivityAt: at(1), owesTurn: true)
        XCTAssertFalse(row.isWorking)
        XCTAssertFalse(row.isActivelyWorking(now: now))
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
    }

    /// A background command or agent writes nothing to the transcript while it
    /// runs — that is what backgrounding is — so the quiet clock cannot answer
    /// for this stretch, and the host's task set keeps the spinner on instead.
    /// Without this the row goes grey the moment the turn ends, which reads as
    /// done under a sweep that runs for ten more minutes.
    func testBackgroundWorkSpinsThroughTheQuiet() {
        let row = makeRow("sweep", state: .idle, hostPID: 84_944,
                          lastActivityAt: at(1_200), runningTasks: 1)
        XCTAssertTrue(row.isWorking)
        XCTAssertTrue(row.isActivelyWorking(now: now))
        XCTAssertFalse(row.isIdleWhileWorking(now: now), "the task set answers for the quiet")
    }

    /// Compacting writes nothing to the transcript either, and it runs for the
    /// better part of a minute — long enough for the quiet clock to call a
    /// session that cannot answer anything finished.
    func testCompactingSpinsThroughTheQuiet() {
        let row = makeRow("compacting", state: .compacting, hostPID: 84_944,
                          lastActivityAt: at(60))
        XCTAssertTrue(row.isCompacting)
        XCTAssertTrue(row.isActivelyWorking(now: now))
        XCTAssertFalse(row.isIdleWhileWorking(now: now))
    }

    /// A message sent while the work is out is a real turn again — a think to
    /// interrupt, measured by the transcript's clock — so the waiting reading
    /// steps aside rather than holding the Stop button off the opening think.
    func testAnOwedTurnOutranksBackgroundWork() {
        let row = makeRow("sent", state: .idle, hostPID: 84_944,
                          lastActivityAt: at(1), owesTurn: true, runningTasks: 1)
        XCTAssertFalse(row.isAwaitingBackgroundWork)
        XCTAssertTrue(row.isActivelyWorking(now: now))
    }

    /// An ask outranks the background work behind it: asking is the one state
    /// where the session is waiting on you, whatever else it still has out.
    func testAQuestionOutranksBackgroundWork() {
        let row = makeRow("asking", state: .asking, hostPID: 84_944,
                          lastActivityAt: at(1), runningTasks: 1)
        XCTAssertFalse(row.isWorking)
        XCTAssertFalse(row.isActivelyWorking(now: now))
    }
}

final class TranscriptLocatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("locator-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/-Users-me-Projects-foo"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeTranscript(_ sessionID: String, project: String = "-Users-me-Projects-foo") throws -> URL {
        let url = root
            .appendingPathComponent("projects/\(project)")
            .appendingPathComponent("\(sessionID).jsonl")
        try "{}\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testFindsATranscriptBySessionID() throws {
        let url = try writeTranscript("abc")
        let locator = TranscriptLocator(configDirectory: root)
        XCTAssertEqual(
            locator.locate(sessionID: "abc")?.standardizedFileURL,
            url.standardizedFileURL
        )
    }

    /// A session that moves into a worktree is filed under a project folder
    /// named for its new directory, and the one it left behind stays put.
    func testASessionFiledTwiceResolvesToTheOneStillBeingWritten() throws {
        let project = "-Users-me-Projects-foo--claude-worktrees-fix"
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/\(project)"),
            withIntermediateDirectories: true
        )
        let leftBehind = try writeTranscript("abc")
        let moved = try writeTranscript("abc", project: project)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)],
            ofItemAtPath: leftBehind.path
        )

        let locator = TranscriptLocator(configDirectory: root)
        XCTAssertEqual(
            locator.locate(sessionID: "abc")?.standardizedFileURL,
            moved.standardizedFileURL
        )
    }

    func testReturnsNilWhenThereIsNoTranscriptAtAll() {
        let locator = TranscriptLocator(configDirectory: root)
        XCTAssertNil(locator.locate(sessionID: "missing"))
    }

    func testReturnsNilWithoutASessionID() {
        let locator = TranscriptLocator(configDirectory: root)
        XCTAssertNil(locator.locate(sessionID: nil))
    }

    func testReadsAModificationTime() throws {
        let url = try writeTranscript("abc")
        let locator = TranscriptLocator(configDirectory: root)
        let written = try XCTUnwrap(locator.lastWrite(at: url))
        XCTAssertLessThan(abs(written.timeIntervalSinceNow), 60)
    }

    func testMissingFileHasNoModificationTime() {
        let locator = TranscriptLocator(configDirectory: root)
        XCTAssertNil(locator.lastWrite(at: root.appendingPathComponent("nope.jsonl")))
    }
}
