import XCTest

@testable import DexCore

private func summary(
    _ key: String,
    sessionId: String? = nil,
    state: HostSessionState = .running,
    startedAt: String = "2026-08-11T00:00:00Z",
    lastActivityAt: String? = nil
) -> HostSessionSummary {
    HostSessionSummary(
        key: key,
        sessionId: sessionId,
        cwd: "/tmp/\(key)",
        name: key,
        state: state,
        model: nil,
        permissionMode: "default",
        startedAt: startedAt,
        lastActivityAt: lastActivityAt
    )
}

private func welcome(
    _ sessions: [HostSessionSummary],
    modes: [String] = ["default"],
    efforts: [String]? = nil,
    outputStyles: [String]? = nil,
    sdk: String = "0.3.227",
    sdkOnDisk: String? = "0.3.227",
    build: String? = nil,
    busy: Bool? = nil
) -> HostEvent {
    .welcome(
        HostWelcome(
            host: "0.1.0", sdk: sdk, sdkOnDisk: sdkOnDisk, build: build, busy: busy, modes: modes,
            efforts: efforts, outputStyles: outputStyles, pid: 4242,
            sessions: sessions, pending: [], protocolVersion: 1
        )
    )
}

private func sessionInit(
    key: String,
    sessionID: String = "uuid-1",
    outputStyle: String? = nil,
    effort: String? = nil
) -> HostSessionInit {
    HostSessionInit(
        key: key, sessionId: sessionID, cwd: "/tmp/work", model: "claude-opus-5",
        permissionMode: "default", outputStyle: outputStyle, effort: effort, tools: []
    )
}

private func ask(_ id: String, key: String = "s1") -> HostAsk {
    HostAsk(
        askId: id, key: key, kind: .permission, toolName: "Write",
        input: .object(["file_path": .string("/tmp/x")]),
        options: [HostAskOption(optionId: "allow_once", name: "Allow", kind: .allowOnce)]
    )
}

final class HostSessionIndexTests: XCTestCase {

    func testAStartedSessionIsKnownBeforeItHasATranscript() {
        var index = HostSessionIndex()
        index.apply(
            .sessionInit(
                HostSessionInit(
                    key: "k1", sessionId: "uuid-1", cwd: "/tmp/work",
                    model: "claude-opus-5", permissionMode: "plan", outputStyle: nil, tools: ["Read"]
                )
            )
        )

        let session = index.sessions["k1"]
        XCTAssertEqual(session?.sessionId, "uuid-1")
        XCTAssertEqual(session?.cwd, "/tmp/work")
        XCTAssertEqual(session?.permissionMode, "plan")
        XCTAssertEqual(index.summary(sessionID: "uuid-1")?.key, "k1")
    }

    func testInitCarriesTheCommandsTheSessionWillRun() {
        var index = HostSessionIndex()
        index.apply(
            .sessionInit(
                HostSessionInit(
                    key: "k1", sessionId: "uuid-1", cwd: "/tmp/work",
                    model: nil, permissionMode: "default", outputStyle: nil, tools: [],
                    commands: ["model", "context"]
                )
            )
        )

        XCTAssertEqual(index.sessions["k1"]?.commands, ["model", "context"])
    }

    /// A host from before the field was on the wire sends none, and a menu that
    /// greys every row is worse than one that greys none.
    func testAHostThatNamesNoCommandsLeavesTheOnesAlreadyKnown() {
        var index = HostSessionIndex()
        let init1 = HostSessionInit(
            key: "k1", sessionId: "uuid-1", cwd: "/tmp/work",
            model: nil, permissionMode: "default", outputStyle: nil, tools: [], commands: ["model"]
        )
        index.apply(.sessionInit(init1))
        index.apply(
            .sessionInit(
                HostSessionInit(
                    key: "k1", sessionId: "uuid-1", cwd: "/tmp/work",
                    model: nil, permissionMode: "default", outputStyle: nil, tools: []
                )
            )
        )

        XCTAssertEqual(index.sessions["k1"]?.commands, ["model"])
    }

    func testInitKeepsTheStartTimeAndNameAlreadyKnown() {
        var index = HostSessionIndex()
        index.apply(
            .welcome(
                HostWelcome(
                    host: "0.1.0", sdk: "0.3.227", sdkOnDisk: "0.3.227", build: nil, busy: nil, modes: ["default"], efforts: nil, outputStyles: nil, pid: 4242,
                    sessions: [summary("k1", startedAt: "2026-01-01T00:00:00Z")],
                    pending: [], protocolVersion: 1
                )
            )
        )
        index.apply(
            .sessionInit(
                HostSessionInit(
                    key: "k1", sessionId: "uuid-1", cwd: "/tmp/k1",
                    model: nil, permissionMode: "default", outputStyle: nil, tools: []
                )
            )
        )

        XCTAssertEqual(index.sessions["k1"]?.startedAt, "2026-01-01T00:00:00Z")
        XCTAssertEqual(index.sessions["k1"]?.name, "k1", "init must not forget a name it never carried")
    }

    func testStatusForASessionWeNeverSawIsIgnoredRatherThanInventingOne() {
        var index = HostSessionIndex()
        index.apply(.sessionStatus(key: "ghost", state: .running))
        XCTAssertTrue(index.sessions.isEmpty)
    }

    func testReconnectingInheritsTheQuestionsRaisedWhileAway() {
        var index = HostSessionIndex()
        index.apply(.ask(ask("stale")))

        index.apply(
            .welcome(
                HostWelcome(
                    host: "0.1.0", sdk: "0.3.227", sdkOnDisk: "0.3.227", build: nil, busy: nil, modes: ["default"], efforts: nil, outputStyles: nil, pid: 4242,
                    sessions: [summary("k1", sessionId: "uuid-1")],
                    pending: [ask("a"), ask("b")], protocolVersion: 1
                )
            )
        )

        XCTAssertEqual(index.asks.count, 2, "the welcome replaces what we thought, it does not add to it")
        XCTAssertEqual(index.asks.pending.map(\.askId), ["a", "b"])
        XCTAssertEqual(index.sessions.count, 1)
    }

    func testASessionEndingTakesItsAsksWithIt() {
        var index = HostSessionIndex()
        index.apply(
            .welcome(
                HostWelcome(
                    host: "0.1.0", sdk: "0.3.227", sdkOnDisk: "0.3.227", build: nil, busy: nil, modes: [], efforts: nil, outputStyles: nil, pid: 4242,
                    sessions: [summary("s1"), summary("s2", startedAt: "2026-08-11T00:00:01Z")],
                    pending: [], protocolVersion: 1
                )
            )
        )
        index.apply(.ask(ask("a", key: "s1")))
        index.apply(.ask(ask("b", key: "s2")))

        index.apply(.sessionExit(key: "s1", reason: "ended"))

        XCTAssertNil(index.sessions["s1"])
        XCTAssertEqual(index.asks.count, 1)
        XCTAssertEqual(index.asks.pending.first?.key, "s2")
    }

    func testAWithdrawnAskLeavesTheCard() {
        var index = HostSessionIndex()
        index.apply(.ask(ask("a")))
        index.apply(.askWithdrawn(askId: "a", key: "s1"))
        XCTAssertTrue(index.asks.isEmpty)
    }

    func testEventsWeDoNotKnowChangeNothing() {
        var index = HostSessionIndex()
        index.apply(.ask(ask("a")))
        let before = index

        index.apply(.unrecognised(type: "session.vibe"))
        index.apply(.reply(HostReply(id: "r1", ok: true, key: nil, error: nil)))

        XCTAssertEqual(index, before)
    }

    /// A finished turn is news about the session even though it changes no
    /// state, and a hosted row has no job file to move its clock otherwise.
    func testAFinishedTurnStillMovesTheRowsClock() {
        var index = HostSessionIndex()
        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        index.apply(.ask(ask("a", key: "s1")), heardAt: early)
        XCTAssertEqual(index.lastEventAt["s1"], early)

        index.apply(
            .sessionResult(HostSessionResult(key: "s1", subtype: "success", costUSD: 0.1, turns: 2)),
            heardAt: later
        )
        XCTAssertEqual(index.lastEventAt["s1"], later)
    }

    /// The row's clock is conversation, not news about the session: a
    /// subagent's bookends, a restated mode, and a withdrawn ask all change
    /// state without anyone having said anything, and stamping them bumped
    /// rows up the list while only an agent was running.
    func testHousekeepingEventsDoNotMoveTheRowsClock() {
        var index = HostSessionIndex()
        let early = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        index.apply(.ask(ask("a", key: "s1")), heardAt: early)
        XCTAssertEqual(index.lastEventAt["s1"], early)

        index.apply(
            .sessionTasks(
                key: "s1",
                tasks: [HostTask(taskId: "t1", toolUseId: "call_1", description: "sweep")]
            ),
            heardAt: later
        )
        index.apply(.sessionMode(key: "s1", permissionMode: "auto"), heardAt: later)
        index.apply(.askWithdrawn(askId: "a", key: "s1"), heardAt: later)

        XCTAssertEqual(index.lastEventAt["s1"], early)
    }

    /// Sent to a busy session the message is queued and the socket says
    /// nothing until the turn ends, so the send is the app's own stamp.
    func testSendingAMessageMovesTheRowsClock() {
        var index = HostSessionIndex()
        index.apply(.ask(ask("a", key: "s1")), heardAt: Date(timeIntervalSince1970: 1_000))

        index.touched(key: "s1", at: Date(timeIntervalSince1970: 2_000))

        XCTAssertEqual(index.lastEventAt["s1"], Date(timeIntervalSince1970: 2_000))
    }

    func testConnectingDatesASessionByTheHostsRecordRatherThanTheConnection() {
        var index = HostSessionIndex()
        index.apply(
            welcome([summary("s1", lastActivityAt: "2026-08-11T00:05:00Z")]),
            heardAt: Date(timeIntervalSince1970: 2_000_000_000)
        )

        XCTAssertEqual(
            index.lastEventAt["s1"],
            HostTimestamp.date("2026-08-11T00:05:00Z")
        )
    }

    /// A host from an older build sends no record of its own, and its welcome is
    /// otherwise perfectly usable.
    func testAHostThatKeepsNoRecordIsStillDatedByWhenWeHeardFromIt() {
        var index = HostSessionIndex()
        let connected = Date(timeIntervalSince1970: 2_000_000_000)
        index.apply(welcome([summary("s1")]), heardAt: connected)

        XCTAssertEqual(index.lastEventAt["s1"], connected)
    }

    /// The whole point of the host's record: a hosted row dismissed in one run
    /// of the app is still dismissed in the next.
    func testARowDismissedLastRunIsStillDismissedAfterRelaunching() {
        let idle = [
            summary("s1", sessionId: "uuid-1", state: .idle, lastActivityAt: "2026-08-11T00:05:00Z")
        ]
        let dismissedAt = Date(timeIntervalSince1970: 1_800_000_000)

        var firstRun = HostSessionIndex()
        firstRun.apply(welcome(idle), heardAt: Date(timeIntervalSince1970: 1_790_000_000))
        guard let row = firstRun.rows().first else { return XCTFail("the welcome named a session") }

        var resolutions = SessionResolutions()
        resolutions.resolve(row, at: dismissedAt)
        XCTAssertTrue(resolutions.isSettled(row))

        var relaunched = HostSessionIndex()
        relaunched.apply(welcome(idle), heardAt: Date(timeIntervalSince1970: 1_900_000_000))
        guard let sameRow = relaunched.rows().first else { return XCTFail("the welcome named a session") }

        XCTAssertTrue(resolutions.isSettled(sameRow))
    }

    func testOrderIsByStartTimeAndStableWhenTheyTie() {
        var index = HostSessionIndex()
        index.apply(
            .welcome(
                HostWelcome(
                    host: "0.1.0", sdk: "0.3.227", sdkOnDisk: "0.3.227", build: nil, busy: nil, modes: [], efforts: nil, outputStyles: nil, pid: 4242,
                    sessions: [
                        summary("b", startedAt: "2026-08-11T00:00:00Z"),
                        summary("a", startedAt: "2026-08-11T00:00:00Z"),
                        summary("c", startedAt: "2026-08-10T00:00:00Z"),
                    ],
                    pending: [], protocolVersion: 1
                )
            )
        )
        XCTAssertEqual(index.ordered.map(\.key), ["c", "a", "b"])
    }

    // The session's own word for its mode

    /// `session.mode` is the only word for a mode the CLI moved itself —
    /// approving a plan lands the session in auto with nothing else saying so —
    /// and the archive records the summary it moves.
    func testTheSessionsOwnWordMovesTheMode() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1")]))

        index.apply(.sessionMode(key: "s1", permissionMode: "auto"))
        XCTAssertEqual(index.sessions["s1"]?.permissionMode, "auto")
    }

    /// The welcome is the only place a host says which modes it takes, and a
    /// host that outlived the app says a shorter list than the app knows. No
    /// picker reads it since the mode UI came out; the host's claim is pinned
    /// so the reading is there when one does again.
    func testTheWelcomeSaysWhichModesTheHostTakes() {
        var index = HostSessionIndex()
        XCTAssertEqual(index.acceptedModes, [], "nothing is claimed before hello")

        index.apply(welcome([summary("s1")], modes: ["default", "plan", "acceptEdits"]))
        XCTAssertEqual(index.acceptedModes, ["default", "plan", "acceptEdits"])

        index.clear()
        XCTAssertEqual(index.acceptedModes, [], "and the claim goes with the connection")
    }

    /// The pair the settings menu reads to say whether replacing the host would
    /// change anything. Both halves come off the welcome — the app has no other
    /// word for which build the process holding the socket began under.
    func testTheWelcomeSaysWhichBuildTheHostBeganUnder() {
        var index = HostSessionIndex()
        XCTAssertNil(index.sdk, "nothing is claimed before hello")

        index.apply(welcome([summary("s1")], sdk: "0.3.227", sdkOnDisk: "0.3.238"))
        XCTAssertEqual(index.sdk, HostSDK(loaded: "0.3.227", onDisk: "0.3.238"))
        XCTAssertTrue(index.sdk?.isBehind == true)

        index.clear()
        XCTAssertNil(index.sdk, "and the claim goes with the connection")
    }

    func testAModeReportForASessionTheHostNeverNamedChangesNothing() {
        var index = HostSessionIndex()
        index.apply(.sessionMode(key: "ghost", permissionMode: "plan"))
        XCTAssertTrue(index.sessions.isEmpty)
    }

    // MARK: - What a session has running

    private func task(_ taskID: String, from toolUseID: String?) -> HostTask {
        HostTask(taskId: taskID, toolUseId: toolUseID, description: "review the diff")
    }

    private func watcher(_ taskID: String, from toolUseID: String?) -> HostTask {
        HostTask(
            taskId: taskID,
            toolUseId: toolUseID,
            description: "watch the build log",
            tool: "Monitor"
        )
    }

    /// What gates replacing a stale host from the app's side: a turn, a
    /// question, or anything still out, a watcher included.
    func testWorkIsATurnAQuestionOrAnythingStillOut() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1", state: .idle), summary("s2", state: .done)]))
        XCTAssertFalse(index.holdsWork)

        for state in [HostSessionState.starting, .running, .compacting, .asking, .unknown("new")] {
            index.apply(.sessionStatus(key: "s1", state: state))
            XCTAssertTrue(index.holdsWork, state.raw)
        }
        index.apply(.sessionStatus(key: "s1", state: .idle))
        XCTAssertFalse(index.holdsWork)

        index.apply(.sessionTasks(key: "s1", tasks: [watcher("w1", from: "toolu_w")]))
        XCTAssertTrue(index.holdsWork)
        index.apply(.sessionTasks(key: "s1", tasks: []))
        XCTAssertFalse(index.holdsWork)

        index.apply(.ask(ask("a", key: "s1")))
        XCTAssertTrue(index.holdsWork)
    }

    /// Found by the call it came from, which is the only name the transcript
    /// knows an agent by.
    func testARunningTaskIsFoundByTheCallItCameFrom() {
        var index = HostSessionIndex()
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: "toolu_a")]))

        XCTAssertEqual(index.task(forKey: "s1", toolUseID: "toolu_a")?.taskId, "t1")
        XCTAssertNil(index.task(forKey: "s1", toolUseID: "toolu_b"))
        XCTAssertNil(index.task(forKey: "other", toolUseID: "toolu_a"))
    }

    /// A level, not a change: what the host sends replaces what was held. A set
    /// that merged instead would leave a Stop on the row of an agent that came
    /// back, and pressing it would name a task the CLI has forgotten.
    func testTheNewestSetIsTheWholeSet() {
        var index = HostSessionIndex()
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: "toolu_a")]))
        index.apply(.sessionTasks(key: "s1", tasks: [task("t2", from: "toolu_b")]))

        XCTAssertNil(index.task(forKey: "s1", toolUseID: "toolu_a"))
        XCTAssertEqual(index.task(forKey: "s1", toolUseID: "toolu_b")?.taskId, "t2")

        index.apply(.sessionTasks(key: "s1", tasks: []))
        XCTAssertNil(index.task(forKey: "s1", toolUseID: "toolu_b"))
    }

    /// A task the host can't name the call for is ambient housekeeping as far
    /// as the app can tell — the SDK registers those without a tool call — so
    /// it neither takes a Stop button nor spins the session's row.
    func testATaskWithNoCallIsDropped() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1", state: .idle)]))
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: nil)]))

        XCTAssertNil(index.task(forKey: "s1", toolUseID: "t1"))
        XCTAssertEqual(index.rows().first?.runningTasks, 0)
        XCTAssertEqual(index.rows().first?.isWorking, false)
    }

    /// What keeps the grey dot honest: a session the host calls idle while it
    /// still holds a background agent or shell command reads as working on the
    /// row, and the emptied set is what takes that back.
    func testBackgroundWorkKeepsAnIdleRowWorking() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1", state: .idle)]))
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: "toolu_a")]))

        guard let row = index.rows().first else { return XCTFail("the welcome named a session") }
        XCTAssertEqual(row.runningTasks, 1)
        XCTAssertTrue(row.isWorking)
        XCTAssertTrue(row.isActivelyWorking())

        index.apply(.sessionTasks(key: "s1", tasks: []))
        XCTAssertEqual(index.rows().first?.isWorking, false)
    }

    /// A monitor is a watcher, not work: it sits in the set for its whole
    /// timeout with the turn long over, so the pane can still list it and stop
    /// it while the row reads idle.
    func testAMonitorIsFoundByItsCallAndCountsAsNothing() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1", state: .idle)]))
        index.apply(.sessionTasks(key: "s1", tasks: [watcher("t1", from: "toolu_a")]))

        XCTAssertEqual(index.task(forKey: "s1", toolUseID: "toolu_a")?.taskId, "t1")
        XCTAssertEqual(index.rows().first?.runningTasks, 0)
        XCTAssertEqual(index.rows().first?.isWorking, false)
    }

    func testWorkBesideAWatcherStillCounts() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1", state: .idle)]))
        index.apply(
            .sessionTasks(
                key: "s1",
                tasks: [watcher("t1", from: "toolu_a"), task("t2", from: "toolu_b")]
            )
        )

        XCTAssertEqual(index.rows().first?.runningTasks, 1)
        XCTAssertEqual(index.rows().first?.isWorking, true)
    }

    /// A host too old to name the call sends no `tool` at all, and the row has
    /// to read that as work: a session spinning while nothing runs is a smaller
    /// wrong than a running agent whose row says it finished.
    func testATaskWithNoToolNameCountsAsWork() {
        var index = HostSessionIndex()
        index.apply(welcome([summary("s1", state: .idle)]))
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: "toolu_a")]))

        XCTAssertNil(index.task(forKey: "s1", toolUseID: "toolu_a")?.tool)
        XCTAssertEqual(index.rows().first?.runningTasks, 1)
    }

    /// A new connection is a new word on everything: whatever tasks were held
    /// were named by the process that used to hold the socket, and the host
    /// sends what is running now behind the welcome.
    func testConnectingAgainDropsWhatTheLastConnectionHeld() {
        var index = HostSessionIndex()
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: "toolu_a")]))
        index.apply(welcome([summary("s1")]))
        XCTAssertNil(index.task(forKey: "s1", toolUseID: "toolu_a"))

        index.apply(.sessionTasks(key: "s1", tasks: [task("t9", from: "toolu_a")]))
        XCTAssertEqual(index.task(forKey: "s1", toolUseID: "toolu_a")?.taskId, "t9")
    }

    func testASessionThatEndsTakesItsTasksWithIt() {
        var index = HostSessionIndex()
        index.apply(.sessionTasks(key: "s1", tasks: [task("t1", from: "toolu_a")]))
        index.apply(.sessionExit(key: "s1", reason: "ended"))
        XCTAssertNil(index.task(forKey: "s1", toolUseID: "toolu_a"))
    }

    // MARK: - Effort and output style

    /// Moved on the host's word, which is the only word there will be: nothing
    /// restates a session's effort the way a `system` message restates its mode.
    func testAnEffortEventMovesTheSessionItNames() {
        var index = HostSessionIndex()
        index.apply(.sessionInit(sessionInit(key: "k1")))
        XCTAssertNil(index.sessions["k1"]?.effort)

        index.apply(.sessionEffort(key: "k1", effort: "max"))
        XCTAssertEqual(index.sessions["k1"]?.effort, "max")
    }

    /// The level a session was started at, off the message that says it
    /// started. It is the only word an app that was already connected will get:
    /// the summary carrying a level rides on the welcome, which such an app had
    /// before the session existed — so without this every session it started
    /// read as Default, and the dial named the settings file's level instead of
    /// the session's.
    func testInitCarriesTheLevelTheSessionWasStartedAt() {
        var index = HostSessionIndex()
        index.apply(.sessionInit(sessionInit(key: "k1", effort: "low")))
        XCTAssertEqual(index.sessions["k1"]?.effort, "low")
    }

    /// A host from before the field names none, and `init` is sent every turn —
    /// so nothing must read as a session having gone back to Default.
    func testAnInitThatNamesNoLevelLeavesTheOneAlreadyKnown() {
        var index = HostSessionIndex()
        index.apply(.sessionInit(sessionInit(key: "k1", effort: "low")))
        index.apply(.sessionEffort(key: "k1", effort: "max"))
        index.apply(.sessionInit(sessionInit(key: "k1")))

        XCTAssertEqual(index.sessions["k1"]?.effort, "max")
    }

    /// Nil is nobody having asked, not a level. The settings files resolved one
    /// and neither the host nor the app can read back which.
    func testTheStyleAndEffortAreNilUntilSomethingSays() {
        var index = HostSessionIndex()
        index.apply(.sessionInit(sessionInit(key: "k1", outputStyle: "ELI5")))

        XCTAssertEqual(index.sessions["k1"]?.outputStyle, "ELI5")
        XCTAssertNil(index.sessions["k1"]?.effort)
    }

    /// An empty list is a host that has not started a session — the styles live
    /// on a running session's `initializationResult()` and nowhere else — so it
    /// must not empty a picker that already had rows.
    func testAnEmptyStyleListDoesNotClearTheOneWeHave() {
        var index = HostSessionIndex()
        index.apply(.outputStyles(["Concise", "ELI5"]))
        XCTAssertEqual(index.outputStyles, ["Concise", "ELI5"])

        index.apply(.outputStyles([]))
        XCTAssertEqual(index.outputStyles, ["Concise", "ELI5"])
    }

    /// Replaced wholesale when there is something to replace it with: a style
    /// file deleted between sessions should leave the picker.
    func testAStyleListReplacesRatherThanMerges() {
        var index = HostSessionIndex()
        index.apply(.outputStyles(["Concise", "ELI5"]))
        index.apply(.outputStyles(["Concise"]))
        XCTAssertEqual(index.outputStyles, ["Concise"])
    }

    /// The host outlives the app. One started before the effort dial existed
    /// says nothing about what it takes, and empty means offer everything.
    func testAHostTooOldToNameItsEffortsSaysNothingRatherThanNone() {
        var index = HostSessionIndex()
        index.apply(welcome([], efforts: nil))
        XCTAssertEqual(index.acceptedEfforts, [])

        index.apply(welcome([], efforts: ["low", "max"]))
        XCTAssertEqual(index.acceptedEfforts, ["low", "max"])
    }

    /// The styles are the machine's, not the connection's — dropping them on a
    /// reconnect would empty the picker for the length of the next host's first
    /// session.
    func testStylesSurviveLosingTheHost() {
        var index = HostSessionIndex()
        index.apply(.outputStyles(["Concise"]))
        index.clear()
        XCTAssertEqual(index.outputStyles, ["Concise"])
        XCTAssertEqual(index.acceptedEfforts, [])
    }

    /// A refused change has to go back to what was there, and what was there is
    /// often nothing at all — nobody had asked, and the settings files resolved
    /// a level neither end can read. Putting back a *name* in that case would
    /// invent one.
    func testARefusedEffortGoesBackToHavingNotBeenAsked() {
        var index = HostSessionIndex()
        index.apply(.sessionInit(sessionInit(key: "k1")))

        index.moved(toEffort: "max", forKey: "k1")
        XCTAssertEqual(index.sessions["k1"]?.effort, "max")

        index.moved(toEffort: nil, forKey: "k1")
        XCTAssertNil(index.sessions["k1"]?.effort)
    }

    // MARK: - What Default resolves to

    /// Kept per folder, because the answer is a merge and a project can hold
    /// settings of its own — the same picker means two things pointed at two
    /// projects.
    func testDefaultsAreRememberedPerFolder() {
        var index = HostSessionIndex()
        index.apply(
            .defaults(
                HostDefaults(cwd: "/a", outputStyle: "ELI5", effort: "xhigh", model: .named("sonnet"))))
        index.apply(.defaults(HostDefaults(cwd: "/b", outputStyle: "Concise", effort: "low")))

        XCTAssertEqual(index.defaults["/a"]?.outputStyle, "ELI5")
        XCTAssertEqual(index.defaults["/a"]?.model, .named("sonnet"))
        XCTAssertEqual(index.defaults["/b"]?.effort, "low")
        XCTAssertEqual(index.defaults["/b"]?.model, .unanswered)
        XCTAssertNil(index.defaults["/c"], "a folder nobody asked about has no answer")
    }

    /// It describes files on disk rather than anything the host holds, so losing
    /// the host is no reason to go back to saying the bare word.
    func testDefaultsSurviveLosingTheHost() {
        var index = HostSessionIndex()
        index.apply(.defaults(HostDefaults(cwd: "/a", outputStyle: "ELI5", effort: "xhigh")))
        index.clear()
        XCTAssertEqual(index.defaults["/a"]?.outputStyle, "ELI5")
    }

    /// Re-asked when a file changes underneath, so the newer answer wins rather
    /// than the first one sticking.
    func testAFolderAskedTwiceTakesTheNewerAnswer() {
        var index = HostSessionIndex()
        index.apply(.defaults(HostDefaults(cwd: "/a", outputStyle: "ELI5", effort: "xhigh")))
        index.apply(.defaults(HostDefaults(cwd: "/a", outputStyle: nil, effort: "low")))

        XCTAssertNil(index.defaults["/a"]?.outputStyle)
        XCTAssertEqual(index.defaults["/a"]?.effort, "low")
    }
}
