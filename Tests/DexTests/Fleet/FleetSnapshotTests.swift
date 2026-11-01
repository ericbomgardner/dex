import XCTest
@testable import DexCore

final class FleetSnapshotTests: XCTestCase {

    private func decode(_ snapshot: FleetSnapshot) throws -> [String: Any] {
        let data = try FleetExport.encode(snapshot)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCarriesTheDashboardOrdering() throws {
        let snapshot = FleetSnapshot(
            rows: [
                makeRow("finished", state: .done),
                makeRow("waiting", state: .asking),
                makeRow("busy", state: .running),
            ],
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        XCTAssertEqual(snapshot.sessions.map(\.name), ["waiting", "busy", "finished"])
    }

    func testReportsWhereTheWorkLands() {
        let row = makeRow(
            "branching",
            state: .running,
            cwd: "/repo/.claude/worktrees/loader",
            worktree: WorktreeOrigin(path: "/repo", branch: "worktree-loader"),
            hostedSummary: "rewriting the loader"
        )

        let session = FleetSession(row)

        XCTAssertEqual(session.cwd, "/repo/.claude/worktrees/loader")
        XCTAssertEqual(session.repository, "/repo")
        XCTAssertEqual(session.branch, "worktree-loader")
        XCTAssertEqual(session.doing, "rewriting the loader")
    }

    func testFallsBackToTheSessionDirectoryOutsideAWorktree() {
        let session = FleetSession(makeRow("plain", state: .running, cwd: "/repo"))

        XCTAssertEqual(session.repository, "/repo")
        XCTAssertNil(session.branch)
    }

    func testCarriesWhatIsBlockingASession() {
        let row = makeRow(
            "stuck",
            state: .asking,
            hostedSummary: "approve the push"
        )

        let session = FleetSession(row)

        XCTAssertEqual(session.state, "blocked")
        XCTAssertEqual(session.waitingFor, "permission prompt")
        XCTAssertEqual(session.doing, "approve the push")
    }

    func testAddressesEachSessionByItsId() throws {
        let snapshot = FleetSnapshot(
            rows: [makeRow("reviewing", state: .running), makeRow("waiting", state: .asking)],
            updatedAt: Date(timeIntervalSince1970: 0)
        ).addressed(by: [
            "uuid-reviewing": .init(address: "kestrel-9d"),
            "uuid-elsewhere": .init(address: "kestrel-c0"),
        ])

        XCTAssertEqual(snapshot.sessions.map(\.address), [nil, "kestrel-9d"])
        XCTAssertEqual(snapshot.sessions.map(\.name), ["waiting", "reviewing"])

        let sessions = try XCTUnwrap(decode(snapshot)["sessions"] as? [[String: Any]])
        XCTAssertNil(sessions[0]["address"])
        XCTAssertEqual(sessions[1]["address"] as? String, "kestrel-9d")
    }

    func testAnAddressChangeIsAChangeWorthWriting() throws {
        let rows = [makeRow("one", state: .running)]
        let unnamed = FleetSnapshot(rows: rows, updatedAt: Date(timeIntervalSince1970: 0))
        let named = unnamed.addressed(by: ["uuid-one": .init(address: "repo-1d")])

        XCTAssertNotEqual(unnamed.sessions, named.sessions)
        XCTAssertEqual(named.sessions, unnamed.addressed(by: ["uuid-one": .init(address: "repo-1d")]).sessions)
    }

    /// The transcript's folder is where the session started; the registry's
    /// follows it into the worktree it entered since.
    func testFollowsASessionIntoTheWorktreeItEntered() {
        let snapshot = FleetSnapshot(
            rows: [makeRow("moved", state: .running, cwd: "/repo")],
            updatedAt: Date(timeIntervalSince1970: 0)
        ).addressed(
            by: ["uuid-moved": .init(address: "Moved", cwd: "/repo/.claude/worktrees/moved")],
            worktree: { $0 == "/repo/.claude/worktrees/moved" ? WorktreeOrigin(path: "/repo", branch: "worktree-moved") : nil }
        )

        let session = snapshot.sessions[0]
        XCTAssertEqual(session.cwd, "/repo/.claude/worktrees/moved")
        XCTAssertEqual(session.repository, "/repo")
        XCTAssertEqual(session.branch, "worktree-moved")
    }

    func testKeepsWhereASessionIsWhenTheRegistryAgrees() {
        let row = makeRow(
            "stayed",
            state: .running,
            cwd: "/repo/.claude/worktrees/stayed",
            worktree: WorktreeOrigin(path: "/repo", branch: "worktree-stayed")
        )
        let snapshot = FleetSnapshot(rows: [row], updatedAt: Date(timeIntervalSince1970: 0)).addressed(
            by: ["uuid-stayed": .init(address: "Stayed", cwd: "/repo/.claude/worktrees/stayed")],
            worktree: { _ in XCTFail("no need to look"); return nil }
        )

        XCTAssertEqual(snapshot.sessions[0].branch, "worktree-stayed")
    }

    func testDistinguishesLandedFromOutstandingWork() {
        let landed = FleetMerge(WorktreeMergeStatus(base: "main", merge: .merged))
        XCTAssertEqual(landed.state, "merged")
        XCTAssertEqual(landed.unmergedCommits, 0)

        let outstanding = FleetMerge(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 3), uncommittedFiles: 2)
        )
        XCTAssertEqual(outstanding.state, "outstanding")
        XCTAssertEqual(outstanding.unmergedCommits, 3)
        XCTAssertEqual(outstanding.uncommittedFiles, 2)
        XCTAssertEqual(outstanding.summary, "3 commits not in main · 2 uncommitted")

        let gone = FleetMerge(WorktreeMergeStatus(base: "main", merge: .branchGone))
        XCTAssertEqual(gone.state, "branchGone")
        XCTAssertNil(gone.unmergedCommits)
    }

    func testOmitsWhatItDoesNotKnow() throws {
        let snapshot = FleetSnapshot(
            rows: [makeRow("bare", state: .idle)],
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let sessions = try XCTUnwrap(decode(snapshot)["sessions"] as? [[String: Any]])

        XCTAssertEqual(sessions[0]["state"] as? String, "stopped")
        XCTAssertEqual(sessions[0]["kind"] as? String, "interactive")
        XCTAssertNil(sessions[0]["merge"])
        XCTAssertNil(sessions[0]["waitingFor"])
        XCTAssertEqual(sessions[0]["running"] as? Bool, false)
    }

    func testStampsTimesAgentsCanCompare() throws {
        let snapshot = FleetSnapshot(
            rows: [makeRow("timed", state: .running, startedAt: 1_700_000_000_000)],
            updatedAt: Date(timeIntervalSince1970: 1_700_000_060)
        )
        let document = try decode(snapshot)

        XCTAssertEqual(document["updatedAt"] as? String, "2023-11-14T22:14:20Z")
        let sessions = try XCTUnwrap(document["sessions"] as? [[String: Any]])
        XCTAssertEqual(sessions[0]["startedAt"] as? String, "2023-11-14T22:13:20Z")
    }
}

final class FleetExportTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleet-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func snapshot(_ rows: [SessionRowModel], at seconds: TimeInterval) -> FleetSnapshot {
        FleetSnapshot(rows: rows, updatedAt: Date(timeIntervalSince1970: seconds))
    }

    func testCreatesTheDirectoryItWritesInto() throws {
        let export = FleetExport(directory: directory)

        XCTAssertTrue(try export.publish(snapshot([makeRow("one", state: .running)], at: 0)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: export.file.path))
    }

    func testSkipsAWriteWhenNothingButTheClockMoved() throws {
        let export = FleetExport(directory: directory)
        let rows = [makeRow("one", state: .running)]

        XCTAssertTrue(try export.publish(snapshot(rows, at: 0)))
        XCTAssertFalse(try export.publish(snapshot(rows, at: 30)))

        let written = try Data(contentsOf: export.file)
        let document = try XCTUnwrap(
            JSONSerialization.jsonObject(with: written) as? [String: Any]
        )
        XCTAssertEqual(document["updatedAt"] as? String, "1970-01-01T00:00:00Z")
    }

    func testWritesAgainWhenTheFleetMoves() throws {
        let export = FleetExport(directory: directory)

        XCTAssertTrue(try export.publish(snapshot([makeRow("one", state: .running)], at: 0)))
        XCTAssertTrue(try export.publish(snapshot([makeRow("one", state: .done)], at: 30)))
    }

    func testWritesAgainWhenTheFileWasDeletedUnderIt() throws {
        let export = FleetExport(directory: directory)
        let rows = [makeRow("one", state: .running)]

        XCTAssertTrue(try export.publish(snapshot(rows, at: 0)))
        try FileManager.default.removeItem(at: export.file)
        XCTAssertTrue(try export.publish(snapshot(rows, at: 30)))
    }
}
