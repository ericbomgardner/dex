import XCTest

@testable import DexCore

private func summary(
    _ key: String,
    sessionId: String? = "uuid-\(1)",
    cwd: String = "/tmp/work",
    name: String? = "a session",
    model: String? = "claude-opus-5",
    state: HostSessionState = .idle,
    startedAt: String = "2026-08-11T00:00:00Z"
) -> HostSessionSummary {
    HostSessionSummary(
        key: key,
        sessionId: sessionId,
        cwd: cwd,
        name: name,
        state: state,
        model: model,
        permissionMode: "plan",
        startedAt: startedAt
    )
}

private let busy = Date(timeIntervalSince1970: 1_800_000_000)

private struct StubProbe: DirectoryProbe {
    var missing: Set<String> = []
    var withheld: Set<String> = []

    func sighting(at path: String) -> DirectorySighting {
        if missing.contains(path) { return .missing }
        if withheld.contains(path) { return .withheld }
        return .directory
    }
}

final class HostedArchiveTests: XCTestCase {


    func testASessionIsRememberedByEverythingAResumeNeeds() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: "uuid-1"), lastActivityAt: busy)

        let entry = archive.entry(key: "k1")
        XCTAssertEqual(entry?.sessionId, "uuid-1")
        XCTAssertEqual(entry?.cwd, "/tmp/work")
        XCTAssertEqual(entry?.model, "claude-opus-5")
        XCTAssertEqual(entry?.permissionMode, "plan")
        XCTAssertEqual(entry?.lastActivityAt, busy)
    }



    func testARenameReachesTheRememberedRow() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: "uuid-1"), lastActivityAt: busy)
        archive.record(summary("k2", sessionId: "uuid-2"), lastActivityAt: busy)
        archive.rename(sessionId: "uuid-1", to: "Billing bug")
        XCTAssertEqual(archive.entry(key: "k1")?.name, "Billing bug")
        XCTAssertEqual(archive.entry(key: "k2")?.name, "a session")
    }


    func testTakingBackAListedSessionKeepsItsRow() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: "uuid-1"), lastActivityAt: busy)
        let later = busy.addingTimeInterval(3600)
        let entry = archive.adopt(sessionId: "uuid-1", cwd: "/tmp/work", name: nil, model: nil,
            now: later
        )

        XCTAssertEqual(entry.key, "k1")
        XCTAssertEqual(archive.stored.count, 1)
        XCTAssertEqual(archive.entry(key: "k1")?.lastActivityAt, later)
    }

    func testASessionWithNoTranscriptIsNotRemembered() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: nil), lastActivityAt: busy)
        XCTAssertTrue(archive.isEmpty)
    }

    func testTheHostsOwnSessionsAreLeftToTheHost() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: "uuid-1"), lastActivityAt: busy)
        archive.record(summary("k2", sessionId: "uuid-2"), lastActivityAt: busy)

        XCTAssertEqual(archive.rows(besides: ["k1"]).map(\.rowID), ["k2"])
        XCTAssertTrue(archive.rows(besides: ["k1", "k2"]).isEmpty)
    }

    /// The row is the same row: same id, same transcript, same clock. Anything
    /// else and its place in the list, and every mark against it, is lost the
    /// moment its host goes.
    func testARememberedRowKeepsTheIdentityItHad() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: "uuid-1"), lastActivityAt: busy)

        guard let row = archive.rows(besides: []).first else {
            return XCTFail("an archived session makes a row")
        }
        XCTAssertEqual(row.rowID, "k1")
        XCTAssertEqual(row.session.sessionId, "uuid-1")
        XCTAssertEqual(row.lastUpdatedAt, busy)
    }

    /// Not done — the session did not end, it is only not running. Done would
    /// also announce it, which is a notification per row when a host goes.
    func testARememberedRowIsIdleRatherThanFinished() {
        var archive = HostedArchive()
        archive.record(summary("k1"), lastActivityAt: busy)
        let row = archive.rows(besides: []).first

        XCTAssertEqual(row?.session.state, .idle)
        XCTAssertNil(row?.session.hostPID, "a pidless row is one the transcript watcher leaves alone")
        XCTAssertEqual(SessionTransitions.change(from: nil, to: row!), .none)
    }

    func testARememberedRowCanBeDismissedAndStaysDismissed() {
        var archive = HostedArchive()
        archive.record(summary("k1"), lastActivityAt: busy)
        guard let row = archive.rows(besides: []).first else { return XCTFail("a row") }

        var resolutions = SessionResolutions()
        XCTAssertTrue(resolutions.canResolve(row))
        resolutions.resolve(row, at: busy.addingTimeInterval(60))
        XCTAssertTrue(resolutions.isSettled(row))
    }

    /// The transcript's own title rather than the name it was started under, and kept
    /// rather than re-read: nothing writes to a stopped session's file, so going
    /// back to it would be a scan of every project directory per row per pass to
    /// be told what the live row already knew.
    func testARememberedRowKeepsWhatTheLiveRowSaid() {
        var archive = HostedArchive()
        archive.record(
            summary("k1", name: "fix the thing"),
            digest: SessionDigest(title: "Resolution marks die at launch", lastMessage: "Running the suite"),
            lastActivityAt: busy
        )

        let row = archive.rows(besides: []).first
        XCTAssertEqual(row?.session.displayName, "Resolution marks die at launch")
        XCTAssertEqual(row?.hostedSummary, "Running the suite")
    }

    /// A line is only replaced by another line. Mid-turn the digest has a title
    /// and no activity, and a row that took that literally would go quiet at the
    /// moment it had most to say.
    func testAnEmptyReadingDoesNotWipeWhatIsAlreadyKept() {
        var archive = HostedArchive()
        archive.record(
            summary("k1", name: "fix the thing"),
            digest: SessionDigest(title: "The CLI's own name", lastMessage: "Running the suite"),
            lastActivityAt: busy
        )
        archive.record(
            summary("k1", name: "fix the thing"),
            digest: SessionDigest(),
            lastActivityAt: busy
        )

        let entry = archive.entry(key: "k1")
        XCTAssertEqual(entry?.lastMessage, "Running the suite")
        XCTAssertEqual(
            entry?.name,
            "The CLI's own name",
            "a name the session was started under stands in rather than replacing one"
        )
    }

    /// The composer clears the draft whichever of these it is, so a wrong answer
    /// here is a message written, sent, and never anywhere.
    func testWhatTypingComesTo() {
        var archive = HostedArchive()
        archive.record(summary("k1", sessionId: "uuid-1"), lastActivityAt: busy)

        XCTAssertEqual(archive.delivery(forKey: "k1", live: ["k1"]), .send)
        XCTAssertEqual(
            archive.delivery(forKey: "k1", live: []),
            .resume(archive.entry(key: "k1")!)
        )
        XCTAssertEqual(archive.delivery(forKey: "forgotten", live: []), .gone)
    }

    /// Its own model, not the composer's: a resume is a launch, and the model
    /// binds at launch.
    func testAResumeIsToldTheSessionsOwnModelAndMode() {
        var archive = HostedArchive()
        archive.record(
            summary("k1", sessionId: "uuid-1", model: "claude-fable-5"),
            lastActivityAt: busy
        )

        guard case .resume(let entry) = archive.delivery(forKey: "k1", live: []) else {
            return XCTFail("a remembered session is resumable")
        }
        XCTAssertEqual(entry.model, "claude-fable-5")
        XCTAssertEqual(entry.permissionMode, "plan")
        XCTAssertEqual(entry.sessionId, "uuid-1")
        XCTAssertEqual(entry.key, "k1", "or it comes back beside the row instead of as it")
    }

    func testWhatNobodyHasTouchedInAWeekIsForgotten() {
        var archive = HostedArchive()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        archive.record(summary("old"), lastActivityAt: now.addingTimeInterval(-HostedArchive.keepFor - 1))
        archive.record(summary("new", sessionId: "uuid-2"), lastActivityAt: now)

        archive.prune(now: now)

        XCTAssertNil(archive.entry(key: "old"))
        XCTAssertNotNil(archive.entry(key: "new"))
    }

    /// A worktree is deleted the moment its branch lands, and the SDK's account
    /// of a cwd it cannot enter blames the binary's libc rather than the folder
    /// — long after the reply that said the resume was accepted.
    func testASessionWhoseFolderIsGoneIsForgotten() {
        var archive = HostedArchive()
        archive.record(summary("landed", cwd: "/tmp/worktree"), lastActivityAt: busy)
        archive.record(summary("live", sessionId: "uuid-2", cwd: "/tmp/work"), lastActivityAt: busy)

        archive.prune(now: busy, probe: StubProbe(missing: ["/tmp/worktree"]))

        XCTAssertNil(archive.entry(key: "landed"))
        XCTAssertNotNil(archive.entry(key: "live"))
    }

    /// A folder macOS won't talk about is one the app hasn't been granted, and
    /// the session in it is still a session.
    func testAWithheldFolderIsNotADeletedOne() {
        var archive = HostedArchive()
        archive.record(summary("k1", cwd: "/tmp/withheld"), lastActivityAt: busy)

        archive.prune(now: busy, probe: StubProbe(withheld: ["/tmp/withheld"]))

        XCTAssertNotNil(archive.entry(key: "k1"))
    }

    /// The host mentions a busy session constantly and this is an encode of
    /// every session ever, on the main actor, for a date nobody reads until the
    /// session is gone.
    func testAClockNudgeAloneIsNotWorthRewriting() {
        var archive = HostedArchive()
        archive.record(summary("k1"), lastActivityAt: busy)
        let first = archive

        archive.record(summary("k1"), lastActivityAt: busy.addingTimeInterval(1))
        XCTAssertEqual(archive, first, "a second later is the same record")

        archive.record(
            summary("k1"),
            lastActivityAt: busy.addingTimeInterval(HostedArchive.clockQuantum + 1)
        )
        XCTAssertNotEqual(archive, first, "half a minute later is not")
    }

    func testAnythingElseIsWorthRewritingHowever() {
        var archive = HostedArchive()
        archive.record(summary("k1", state: .idle), lastActivityAt: busy)

        archive.record(
            summary("k1"),
            digest: SessionDigest(title: "Named at last", lastMessage: nil),
            lastActivityAt: busy.addingTimeInterval(1)
        )

        XCTAssertEqual(archive.entry(key: "k1")?.name, "Named at last")
    }

    func testTheNewestSurviveTheCap() {
        var archive = HostedArchive()
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        for index in 0...HostedArchive.capacity {
            archive.record(
                summary("k\(index)", sessionId: "uuid-\(index)"),
                lastActivityAt: now.addingTimeInterval(-Double(index))
            )
        }

        archive.prune(now: now)

        XCTAssertEqual(archive.stored.count, HostedArchive.capacity)
        XCTAssertNotNil(archive.entry(key: "k0"))
        XCTAssertNil(archive.entry(key: "k\(HostedArchive.capacity)"))
    }

    func testItSurvivesBeingWrittenDownAndReadBack() throws {
        var archive = HostedArchive()
        archive.record(summary("k1"), lastActivityAt: busy)

        let data = try JSONEncoder().encode(archive)
        XCTAssertEqual(try JSONDecoder().decode(HostedArchive.self, from: data), archive)
    }

    /// A resume that names no level lands on whatever the settings files say
    /// now, which is not where the session was — so the level is part of what
    /// coming back means.
    func testASessionIsRememberedAtTheLevelItWasThinkingAt() {
        var archive = HostedArchive()
        var live = summary("k1")
        live.effort = "low"
        archive.record(live, lastActivityAt: busy)

        XCTAssertEqual(archive.entry(key: "k1")?.effort, "low")
    }

    /// Nil is a host with nothing to say, not a session that went back to
    /// Default — and the archive is written from every mention of a session.
    func testAHostThatNamesNoLevelDoesNotForgetTheOneRecorded() {
        var archive = HostedArchive()
        var live = summary("k1")
        live.effort = "low"
        archive.record(live, lastActivityAt: busy)
        archive.record(summary("k1"), lastActivityAt: busy.addingTimeInterval(600))

        XCTAssertEqual(archive.entry(key: "k1")?.effort, "low")
    }

    /// The app never moves a style on a running session — one app-wide pick,
    /// no dial — so the resume is the only moment there is to ask for one, and
    /// asking for nothing hands a half-written conversation to whatever the
    /// settings files say now.
    func testASessionIsRememberedByHowItWasWriting() {
        var archive = HostedArchive()
        var live = summary("k1")
        live.outputStyle = "ELI5"
        archive.record(live, lastActivityAt: busy)

        XCTAssertEqual(archive.entry(key: "k1")?.outputStyle, "ELI5")
    }

    /// The style arrives on `session.init`, which a session has not sent when
    /// `start` first answers — so the row is recorded once before there is a
    /// style to record, and that pass must not be the one that sticks.
    func testASummaryWithNoStyleDoesNotForgetTheOneRecorded() {
        var archive = HostedArchive()
        var live = summary("k1")
        live.outputStyle = "ELI5"
        archive.record(live, lastActivityAt: busy)
        archive.record(summary("k1"), lastActivityAt: busy.addingTimeInterval(600))

        XCTAssertEqual(archive.entry(key: "k1")?.outputStyle, "ELI5")
    }


    /// An archive written before origins existed must still decode: a field
    /// added without a default once wiped the whole archive.
    func testAnEntryWithoutAnOriginStillDecodes() throws {
        let stored = Data(
            """
            {"key":"k1","sessionId":"s1","cwd":"/tmp","permissionMode":"auto",\
            "startedAt":"2026-09-01T10:00:00Z","lastActivityAt":768000000}
            """.utf8
        )
        let entry = try JSONDecoder().decode(HostedArchive.Entry.self, from: stored)
        XCTAssertNil(entry.origin)
    }

    /// A resume is started by the app, which sends no origin, so the watcher
    /// that started the conversation has to be kept.
    func testAnOriginIsKeptThroughAResumeAndReachesTheRow() throws {
        var archive = HostedArchive()
        var started = summary("k1", sessionId: "s1")
        started.origin = SessionOrigin(watcher: "ci-watch", reason: "tests failed")
        archive.record(started, lastActivityAt: busy)
        archive.record(summary("k1", sessionId: "s1"), lastActivityAt: busy.addingTimeInterval(600))

        let read = try JSONDecoder().decode(HostedArchive.self, from: JSONEncoder().encode(archive))
        XCTAssertEqual(read.entry(key: "k1")?.origin?.watcher, "ci-watch")
        XCTAssertEqual(read.rows(besides: []).first?.origin?.reason, "tests failed")
    }
}
