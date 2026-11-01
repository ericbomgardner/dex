import XCTest

@testable import DexCore

private let newYork: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/New_York")!
    return calendar
}()

private func at(_ text: String) -> Date {
    TranscriptTimestamp.parse(text)!
}

private func watcher(
    _ json: String,
    id: String = "w",
    modifiedAt: Date = at("2026-09-30T12:00:00-04:00")
) -> BackgroundWatcher {
    let reading: BackgroundWatcher.Reading
    do {
        reading = .status(try BackgroundWatcherStatus.read(Data(json.utf8), fallbackName: id))
    } catch {
        reading = .unreadable("\(error)")
    }
    return BackgroundWatcher(id: id, file: URL(fileURLWithPath: "/tmp/\(id).json"), modifiedAt: modifiedAt, reading: reading)
}

private func every(_ seconds: Int, finished: String, result: String = "ok") -> BackgroundWatcher {
    watcher(
        """
        {"version":1,"name":"ci-watch","schedule":{"every":\(seconds)},
         "lastRun":{"startedAt":"\(finished)","finishedAt":"\(finished)","result":"\(result)"}}
        """
    )
}

private func daily(_ time: String, finished: String) -> BackgroundWatcher {
    watcher(
        """
        {"version":1,"name":"digest","schedule":{"daily":"\(time)"},
         "lastRun":{"finishedAt":"\(finished)","result":"idle"}}
        """
    )
}

final class BackgroundWatcherTests: XCTestCase {

    func testTheContractsExampleReadsInFull() throws {
        let status = try XCTUnwrap(
            watcher(
                """
                {"version":1,"name":"ci-watch",
                 "description":"Starts a session to diagnose each failed CI run on my open PRs",
                 "launchdLabel":"com.example.ci-watch","schedule":{"every":180},
                 "logPath":"~/.claude/ci-watch/log",
                 "lastRun":{"startedAt":"2026-09-30T18:59:54-04:00","finishedAt":"2026-09-30T18:59:56-04:00",
                            "result":"failed","summary":"the script crashed","error":"FileNotFoundError: 'gh'"},
                 "lastSuccessAt":"2026-09-30T18:56:50-04:00",
                 "sessions":[{"key":"k1","name":"CI fail: feature/foo","startedAt":"2026-09-30T18:50:00-04:00",
                              "reason":"tests failed on PR #12","url":"https://example.com"}]}
                """
            ).status)

        XCTAssertEqual(status.name, "ci-watch")
        XCTAssertEqual(status.launchdLabel, "com.example.ci-watch")
        XCTAssertEqual(status.schedule, .every(180))
        XCTAssertEqual(status.lastRun?.result, .failed)
        XCTAssertEqual(status.lastRun?.error, "FileNotFoundError: 'gh'")
        XCTAssertEqual(status.lastSuccessAt, at("2026-09-30T18:56:50-04:00"))
        XCTAssertEqual(status.sessions.first?.key, "k1")
        XCTAssertEqual(status.sessions.first?.reason, "tests failed on PR #12")
        XCTAssertFalse(status.expandedLogPath!.hasPrefix("~"))
    }

    /// A watcher that drops out of the list is the one failure nobody would
    /// see, so a file that won't read stays in it, saying why.
    func testAFileThatWontReadIsShownAsUnreadable() {
        let broken = watcher("{\"name\":")
        XCTAssertNil(broken.status)
        let health = BackgroundWatcherHealth.of(broken, now: at("2026-09-30T12:00:00-04:00"))
        guard case .unreadable = health.condition else { return XCTFail("not unreadable") }
        XCTAssertTrue(health.needsAttention)
    }

    func testAFieldThatWontReadIsDroppedNotTheFile() throws {
        let status = try XCTUnwrap(
            watcher(#"{"name":"x","schedule":{"daily":"25:00"},"sessions":[{"name":"no key"}],"lastSuccessAt":3}"#).status
        )
        XCTAssertNil(status.schedule)
        XCTAssertTrue(status.sessions.isEmpty)
        XCTAssertNil(status.lastSuccessAt)
    }

    func testAFileWithNoNameIsCalledByItsFileName() {
        XCTAssertEqual(watcher(#"{"version":1}"#, id: "nightly").name, "nightly")
    }

    func testANewerVersionIsReadAndFlagged() {
        let health = BackgroundWatcherHealth.of(
            watcher(#"{"version":2,"name":"x"}"#), now: at("2026-09-30T12:00:00-04:00"))
        XCTAssertTrue(health.isNewerFormat)
    }

    func testAnUnknownResultIsShownButNotAlarmedOn() {
        let health = BackgroundWatcherHealth.of(
            every(180, finished: "2026-09-30T12:00:00-04:00", result: "skipped"),
            now: at("2026-09-30T12:01:00-04:00"))
        XCTAssertEqual(health.condition, .other("skipped"))
        XCTAssertFalse(health.needsAttention)
    }

    func testAFailedRunNeedsAttention() {
        let health = BackgroundWatcherHealth.of(
            every(180, finished: "2026-09-30T12:00:00-04:00", result: "failed"),
            now: at("2026-09-30T12:01:00-04:00"))
        XCTAssertEqual(health.condition, .failed)
        XCTAssertFalse(health.isStale)
        XCTAssertTrue(health.needsAttention)
    }

    // MARK: every N

    func testAnIntervalWatcherIsStalePastThreeIntervals() {
        let run = every(3600, finished: "2026-09-30T12:00:00-04:00")
        XCTAssertFalse(BackgroundWatcherHealth.of(run, now: at("2026-09-30T14:59:00-04:00")).isStale)
        XCTAssertTrue(BackgroundWatcherHealth.of(run, now: at("2026-09-30T15:01:00-04:00")).isStale)
    }

    func testAShortIntervalGetsTheTenMinuteFloor() {
        let run = every(60, finished: "2026-09-30T12:00:00-04:00")
        XCTAssertFalse(BackgroundWatcherHealth.of(run, now: at("2026-09-30T12:09:00-04:00")).isStale)
        XCTAssertTrue(BackgroundWatcherHealth.of(run, now: at("2026-09-30T12:11:00-04:00")).isStale)
    }

    func testTheNextIntervalRunCountsFromTheLastStart() {
        let run = every(180, finished: "2026-09-30T12:00:00-04:00")
        XCTAssertEqual(
            BackgroundWatcherHealth.of(run, now: at("2026-09-30T12:01:00-04:00")).nextRunAt,
            at("2026-09-30T12:03:00-04:00"))
    }

    // MARK: daily

    func testADailyWatcherIsStaleTwoHoursAfterAMissedRun() {
        let ranYesterday = daily("09:00", finished: "2026-09-29T09:00:30-04:00")
        XCTAssertFalse(
            BackgroundWatcherHealth.of(ranYesterday, now: at("2026-09-30T10:59:00-04:00"), calendar: newYork).isStale)
        XCTAssertTrue(
            BackgroundWatcherHealth.of(ranYesterday, now: at("2026-09-30T11:01:00-04:00"), calendar: newYork).isStale)
    }

    func testADailyWatcherThatRanTodayIsNotStale() {
        let ranToday = daily("09:00", finished: "2026-09-30T09:00:30-04:00")
        XCTAssertFalse(
            BackgroundWatcherHealth.of(ranToday, now: at("2026-09-30T23:00:00-04:00"), calendar: newYork).isStale)
    }

    /// Before today's time has come, the run that counts is yesterday's.
    func testBeforeTodaysTimeYesterdaysRunIsTheOneThatCounts() {
        let ranTwoDaysAgo = daily("23:00", finished: "2026-09-28T23:00:30-04:00")
        XCTAssertTrue(
            BackgroundWatcherHealth.of(ranTwoDaysAgo, now: at("2026-09-30T08:00:00-04:00"), calendar: newYork).isStale)
        let ranLastNight = daily("23:00", finished: "2026-09-29T23:00:30-04:00")
        XCTAssertFalse(
            BackgroundWatcherHealth.of(ranLastNight, now: at("2026-09-30T08:00:00-04:00"), calendar: newYork).isStale)
    }

    func testTheNextDailyRunIsTheNextTimeOfDay() {
        let run = daily("09:00", finished: "2026-09-30T09:00:30-04:00")
        XCTAssertEqual(
            BackgroundWatcherHealth.of(run, now: at("2026-09-30T10:00:00-04:00"), calendar: newYork).nextRunAt,
            at("2026-10-01T09:00:00-04:00"))
    }

    // MARK: sleep and never-run

    /// A Mac that slept through its runs isn't a dead watcher: launchd runs it
    /// on wake, and that run gets a moment to land.
    func testNothingIsStaleJustAfterTheMacWakes() {
        let run = every(180, finished: "2026-09-30T02:00:00-04:00")
        let now = at("2026-09-30T08:05:00-04:00")
        XCTAssertFalse(
            BackgroundWatcherHealth.of(run, now: now, lastWake: at("2026-09-30T08:00:00-04:00")).isStale)
        XCTAssertTrue(
            BackgroundWatcherHealth.of(run, now: now, lastWake: at("2026-09-30T07:50:00-04:00")).isStale)
    }

    /// The grace hides staleness; it is not a recovery, so an alert already out
    /// has to be left standing rather than cleared and posted again later.
    func testTheWakeGraceSaysItIsHoldingStalenessBack() {
        let run = every(180, finished: "2026-09-30T02:00:00-04:00", result: "failed")
        let held = BackgroundWatcherHealth.of(
            run, now: at("2026-09-30T08:05:00-04:00"), lastWake: at("2026-09-30T08:00:00-04:00"))
        XCTAssertTrue(held.isHeldByWake)
        let fresh = every(180, finished: "2026-09-30T08:04:00-04:00")
        XCTAssertFalse(
            BackgroundWatcherHealth.of(
                fresh, now: at("2026-09-30T08:05:00-04:00"), lastWake: at("2026-09-30T08:00:00-04:00")
            ).isHeldByWake)
    }

    func testARunWithNoFinishTimeIsDatedByItsStartNotFailed() throws {
        let status = try XCTUnwrap(
            watcher(#"{"name":"x","lastRun":{"startedAt":"2026-09-30T12:00:00-04:00","result":"running"}}"#).status)
        XCTAssertEqual(status.lastRun?.finishedAt, at("2026-09-30T12:00:00-04:00"))
        XCTAssertEqual(status.lastRun?.result, .other("running"))
        XCTAssertNil(watcher(#"{"name":"x","lastRun":{"result":"ok"}}"#).status?.lastRun)
    }

    /// An install can write the file before the first run. The clock then
    /// starts from when it was written.
    func testAWatcherThatNeverRanIsDatedByItsFile() {
        let fresh = watcher(
            #"{"version":1,"name":"x","schedule":{"every":180},"lastRun":null,"sessions":[]}"#,
            modifiedAt: at("2026-09-30T12:00:00-04:00"))
        let soon = BackgroundWatcherHealth.of(fresh, now: at("2026-09-30T12:05:00-04:00"))
        XCTAssertEqual(soon.condition, .neverRan)
        XCTAssertFalse(soon.needsAttention)
        XCTAssertTrue(BackgroundWatcherHealth.of(fresh, now: at("2026-09-30T12:11:00-04:00")).isStale)
    }

    // MARK: alerts

    /// One notification per problem: the same failed run checked again says
    /// the same, and the next failed run says something new.
    func testAnAlertIsKeyedToTheRunItIsAbout() {
        let first = every(180, finished: "2026-09-30T12:00:00-04:00", result: "failed")
        let again = every(180, finished: "2026-09-30T12:03:00-04:00", result: "failed")
        let now = at("2026-09-30T12:04:00-04:00")
        let token = BackgroundWatcherHealth.of(first, now: now).alertToken(for: first)
        XCTAssertNotNil(token)
        XCTAssertEqual(token, BackgroundWatcherHealth.of(first, now: now).alertToken(for: first))
        XCTAssertNotEqual(token, BackgroundWatcherHealth.of(again, now: now).alertToken(for: again))
        let fine = every(180, finished: "2026-09-30T12:03:00-04:00")
        XCTAssertNil(BackgroundWatcherHealth.of(fine, now: now).alertToken(for: fine))
    }

    func testAFailureNotificationSaysWhatWentWrong() throws {
        let failed = watcher(
            """
            {"version":1,"name":"ci-watch","schedule":{"every":180},
             "lastRun":{"finishedAt":"2026-09-30T12:00:00-04:00","result":"failed",
                        "summary":"the script crashed","error":"FileNotFoundError: 'gh'"}}
            """, id: "ci-watch")
        let now = at("2026-09-30T12:01:00-04:00")
        let draft = try XCTUnwrap(
            BackgroundWatcherAlert.draft(failed, BackgroundWatcherHealth.of(failed, now: now), now: now))
        XCTAssertEqual(draft.title, "ci-watch: last run failed")
        XCTAssertEqual(draft.body, "the script crashed\nFileNotFoundError: 'gh'")
        XCTAssertEqual(draft.key, "watcher:ci-watch")
        XCTAssertNil(draft.sessionID)
    }

    func testAStaleNotificationSaysWhenItLastRan() throws {
        let run = every(180, finished: "2026-09-30T12:00:00-04:00")
        let now = at("2026-09-30T14:00:00-04:00")
        let draft = try XCTUnwrap(BackgroundWatcherAlert.draft(run, BackgroundWatcherHealth.of(run, now: now), now: now))
        XCTAssertEqual(draft.title, "ci-watch: hasn't run when it should have")
        XCTAssertEqual(draft.body, "Last ran 2h ago.")
        XCTAssertNil(BackgroundWatcherAlert.draft(run, BackgroundWatcherHealth.of(run, now: at("2026-09-30T12:01:00-04:00")), now: now))
    }

    func testTheFilterKeepsOnlyTheWatchersSessionsAndCountsTheWaitingRest() {
        let mine = SessionRowModel(
            session: makeSession("a", state: .running), origin: SessionOrigin(watcher: "ci-watch"))
        let other = SessionRowModel(
            session: makeSession("b", state: .asking), owesTurn: true)
        let result = SessionFilter(watcher: "ci-watch").apply(to: [mine, other])
        XCTAssertEqual(result.visible.map(\.rowID), ["a"])
        XCTAssertEqual(SessionFilter().apply(to: [mine, other]).visible.count, 2)
    }

    // MARK: log

    func testTheLogTailIsTheLastLinesWithoutAPartialFirstOne() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("watcher-log-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        let lines = (1...500).map { "line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: file, atomically: true, encoding: .utf8)

        XCTAssertEqual(BackgroundWatcher.logTail(path: file.path, lines: 3), ["line 498", "line 499", "line 500"])
        let tiny = BackgroundWatcher.logTail(path: file.path, lines: 100, bytes: 20)
        XCTAssertEqual(tiny?.last, "line 500")
        XCTAssertTrue(tiny?.allSatisfy { $0.hasPrefix("line ") } ?? false)
        XCTAssertNil(BackgroundWatcher.logTail(path: "/nonexistent/log"))
    }
}
