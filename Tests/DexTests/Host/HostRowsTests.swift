import XCTest

@testable import DexCore

private func summary(
    state: HostSessionState = .running,
    sessionId: String? = "uuid-1",
    startedAt: String = "2026-08-11T00:00:00Z",
    name: String? = "nightly"
) -> HostSessionSummary {
    HostSessionSummary(
        key: "k1",
        sessionId: sessionId,
        cwd: "/tmp/work",
        name: name,
        state: state,
        model: "claude-opus-5",
        permissionMode: "plan",
        startedAt: startedAt
    )
}

/// Each of these is a field the list reads for something non-obvious; the
/// comments say what goes wrong when it is built wrong.
final class HostRowsTests: XCTestCase {

    func testTheHostKeyIsTheRowIdentityForTheSessionsWholeLife() {
        let before = AgentSession(hosted: summary(sessionId: nil), hostPID: 42)
        let after = AgentSession(hosted: summary(sessionId: "uuid-1"), hostPID: 42)

        XCTAssertEqual(before.rowID, "k1")
        XCTAssertEqual(
            before.rowID, after.rowID,
            "the transcript id arriving must not rekey the row under everything holding it"
        )
    }

    /// The count rides the row so the list can say a session with background
    /// work out is not done — the state alone reads idle, which is the grey dot
    /// under a sweep with minutes left to run.
    func testBackgroundTasksRideTheRow() {
        let row = SessionRowModel(hosted: summary(state: .idle), hostPID: 4242, runningTasks: 2)
        XCTAssertEqual(row.runningTasks, 2)
        XCTAssertTrue(row.isWorking)
    }

    /// A nil pid is a row TranscriptWatcher declines to watch, which costs the
    /// row its activity, its spinner and its idle dimming.
    func testThePidIsTheHostsSoTheRowIsWatchedAtAll() {
        let session = AgentSession(hosted: summary(), hostPID: 4242)
        XCTAssertEqual(session.hostPID, 4242)
        XCTAssertTrue(session.isLive)
    }

    /// The pid is the host's and is set for every row it reports, so a session
    /// whose own CLI died while the host stayed up still carries one. Read as
    /// liveness that row claims a call left pending by the death is still
    /// running, and the pane draws a clock on it that never stops.
    func testAFailedSessionCannotAnswerEvenThoughItKeepsTheHostsPid() {
        let failed = AgentSession(hosted: summary(state: .failed), hostPID: 4242)
        XCTAssertTrue(failed.isLive, "the pid is the host's, and the host is up")
        XCTAssertFalse(failed.canAnswer, "nothing is left to write a result into that transcript")

        let running = AgentSession(hosted: summary(state: .running), hostPID: 4242)
        XCTAssertTrue(running.canAnswer)
    }

    /// A row read off disk has no host behind it at all, which is the whole-host
    /// death the SIGTERM reading is about.
    func testAnArchivedRowCannotAnswer() {
        let session = AgentSession(hosted: summary(), hostPID: 42)
        XCTAssertTrue(session.canAnswer)
        XCTAssertFalse(
            AgentSession(
                cwd: session.cwd,
                startedAt: session.startedAt,
                hostKey: session.hostKey,
                state: .idle,
                hostPID: nil,
                sessionId: session.sessionId,
                name: session.name
            ).canAnswer
        )
    }

    func testStartTimesAreMillisecondsRatherThan1970() {
        let session = AgentSession(
            hosted: summary(startedAt: "2026-08-11T00:00:00Z"), hostPID: 42)

        let expected = ISO8601DateFormatter().date(from: "2026-08-11T00:00:00Z")!
        XCTAssertEqual(session.startedAtDate.timeIntervalSince1970,
                       expected.timeIntervalSince1970, accuracy: 1)
    }

    func testAFractionalTimestampIsStillRead() {
        let session = AgentSession(
            hosted: summary(startedAt: "2026-08-11T00:00:00.123Z"), hostPID: 42)
        XCTAssertGreaterThan(session.startedAtDate.timeIntervalSince1970, 1_700_000_000)
    }

    func testAnUnreadableTimestampFallsBackToNowRatherThanToTheEpoch() {
        let session = AgentSession(hosted: summary(startedAt: "not a date"), hostPID: 42)
        XCTAssertEqual(
            session.startedAtDate.timeIntervalSinceNow, 0, accuracy: 5,
            "1970 would sort every hosted row to the bottom forever"
        )
    }

    func testAnAskingRowIsWaitingOnYouRatherThanWorking() {
        let row = SessionRowModel(hosted: summary(state: .asking), hostPID: 42)
        XCTAssertTrue(row.isAsking)
        XCTAssertFalse(row.isWorking)
        XCTAssertEqual(row.activity(), .unknown)
        XCTAssertEqual(row.summary, "waiting: permission prompt")
    }

    func testARunningRowIsWorkingWhateverTheClockSays() {
        let row = SessionRowModel(hosted: summary(state: .running), hostPID: 42)
        XCTAssertTrue(row.isWorking)
        XCTAssertEqual(row.activity(), .active)
    }

    /// Compacting is a stretch of working that writes nothing, so a row that
    /// read it as anything else would go grey with half a minute still to run.
    func testACompactingRowIsWorkingWhateverTheClockSays() {
        let row = SessionRowModel(hosted: summary(state: .compacting), hostPID: 42)
        XCTAssertTrue(row.isWorking)
        XCTAssertEqual(row.activity(), .active)
        XCTAssertFalse(row.session.hasFinishedWorking)
    }

    /// And the line under the title says so: the last message is what the
    /// session was doing before the CLI took the turn away to summarise.
    func testACompactingRowSaysWhatItIsDoing() {
        XCTAssertEqual(
            SessionRowModel.hostedSummary(
                state: .compacting, ask: nil, digest: SessionDigest(lastMessage: "hi")
            ),
            "Compacting…"
        )
    }

    func testTheCompactingFlagRidesTheRow() {
        XCTAssertTrue(SessionRowModel(hosted: summary(state: .compacting), hostPID: 42).isCompacting)
        XCTAssertFalse(SessionRowModel(hosted: summary(state: .running), hostPID: 42).isCompacting)
    }

    func testAStateFromANewerHostIsTreatedAsWorkRatherThanAsFinished() {
        let row = SessionRowModel(hosted: summary(state: .unknown("hibernating")), hostPID: 42)
        XCTAssertTrue(row.isWorking)
        XCTAssertFalse(
            row.session.hasFinishedWorking,
            "guessing 'finished' for a state we don't know retires a live session"
        )
    }

    // MARK: - The row

    func testTheRowsClockMovesWithTheHostRatherThanFreezing() {
        let start = ISO8601DateFormatter().date(from: "2026-08-11T00:00:00Z")!
        let later = start.addingTimeInterval(600)

        let frozen = SessionRowModel(hosted: summary(), hostPID: 42)
        let moved = SessionRowModel(hosted: summary(), hostPID: 42, lastEventAt: later)

        XCTAssertEqual(frozen.lastUpdatedAt.timeIntervalSince1970,
                       start.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(moved.lastUpdatedAt.timeIntervalSince1970,
                       later.timeIntervalSince1970, accuracy: 1)
    }

    func testTheRowCarriesTheModeItIsRunningIn() {
        let row = SessionRowModel(hosted: summary(), hostPID: 42)
        XCTAssertEqual(row.livePermissionMode, "plan")
    }

    func testARowHoldingAQuestionOwesATurn() {
        XCTAssertTrue(SessionRowModel(hosted: summary(state: .asking), hostPID: 42).owesTurn)
        XCTAssertFalse(SessionRowModel(hosted: summary(state: .running), hostPID: 42).owesTurn)
    }

    func testTheRowKeepsTheNameItWasGiven() {
        let row = SessionRowModel(hosted: summary(), hostPID: 42)
        XCTAssertEqual(row.session.displayName, "nightly")
        XCTAssertEqual(row.rowID, "k1")
    }

    /// A session the host has no name for is one the CLI has not named yet — a
    /// second, measured. The folder used to stand in there, which the row says
    /// on its qualifier line and again under the path, so the title was the one
    /// line of the three saying nothing the other two didn't.
    func testARowWithNoNameYetSaysItIsNewRatherThanNamingItsFolder() {
        let row = SessionRowModel(hosted: summary(name: nil), hostPID: 42)

        XCTAssertEqual(row.session.displayName, "New session")
        XCTAssertNotEqual(row.session.displayName, "work")
    }

    /// The row is built from what the host said and rebuilt only when the host
    /// says something else, and a session halfway through a first turn says
    /// nothing for as long as the turn lasts. The file it is writing has the
    /// name in it a second in, so the read that follows a write carries it.
    func testATranscriptWriteCanNameTheRow() {
        let row = SessionRowModel(hosted: summary(name: nil), hostPID: 42)
        let named = row.refreshed(activityAt: Date(), title: "Restore session titles")

        XCTAssertEqual(named.session.displayName, "Restore session titles")
        XCTAssertEqual(named.rowID, row.rowID, "renaming a row must not rekey it")
    }

    /// The name dispatch gave the row, in the one case there still is of one:
    /// a session started under a name somebody chose.
    func testTheTranscriptsTitleOutranksTheOneDispatchGaveIt() {
        let row = SessionRowModel(
            hosted: summary(),
            hostPID: 42,
            digest: SessionDigest(title: "Restore session titles")
        )
        XCTAssertEqual(row.session.displayName, "Restore session titles")
    }

    func testTheNewestActivityIsTheRowsSecondLine() {
        let row = SessionRowModel(
            hosted: summary(),
            hostPID: 42,
            digest: SessionDigest(lastMessage: "tests are green")
        )
        XCTAssertEqual(row.summary, "tests are green")
    }

    /// A session holding something out for you says that instead: it is the one
    /// thing on the row you can act on, and the message behind it is the one that
    /// prompted the ask anyway.
    func testAnAskOutranksTheLastMessage() {
        let ask = HostAsk(
            askId: "a1",
            key: "k1",
            kind: .permission,
            toolName: "Bash",
            input: .object(["command": .string("npm test")]),
            options: []
        )

        let row = SessionRowModel(
            hosted: summary(state: .asking),
            hostPID: 42,
            digest: SessionDigest(lastMessage: "tests are green"),
            ask: ask
        )
        XCTAssertEqual(row.summary, "Bash: npm test")
    }

    /// A question's own text, rather than the tool that raised it — `AskUserQuestion`
    /// on a row says nothing about what is being asked.
    func testAQuestionShowsWhatItAsked() {
        let ask = HostAsk(
            askId: "a2",
            key: "k1",
            kind: .question,
            toolName: "AskUserQuestion",
            input: .object([
                "questions": .array([
                    .object([
                        "question": .string("Which subtitle?"),
                        "options": .array([.object(["label": .string("Last message")])]),
                    ])
                ])
            ]),
            options: []
        )

        let row = SessionRowModel(hosted: summary(state: .asking), hostPID: 42, ask: ask)
        XCTAssertEqual(row.summary, "Which subtitle?")
    }

    /// Withdrawing an ask and moving off `asking` are two messages rather than
    /// one, so a row that trusted the queue alone would keep holding out a
    /// question that has already been answered.
    func testAnAskIsOnlyShownWhileTheSessionIsStillAsking() {
        let ask = HostAsk(
            askId: "a3",
            key: "k1",
            kind: .permission,
            toolName: "Bash",
            input: .object(["command": .string("npm test")]),
            options: []
        )

        let row = SessionRowModel(
            hosted: summary(state: .running),
            hostPID: 42,
            digest: SessionDigest(lastMessage: "tests are green"),
            ask: ask
        )
        XCTAssertEqual(row.summary, "tests are green")
    }

    /// A row with nothing read yet is the row that was there before any of this,
    /// rather than a blank one.
    func testARowWithNothingReadFallsBackToWhatItSaidBefore() {
        let row = SessionRowModel(hosted: summary(state: .running), hostPID: 42)
        XCTAssertEqual(row.summary, Format.shortPath("/tmp/work"))
    }
}
