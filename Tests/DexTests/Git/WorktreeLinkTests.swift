import XCTest
@testable import DexCore

final class WorktreeLinkTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("worktree-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ contents: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    @discardableResult
    private func makeWorktree(
        repo: String = "repo",
        named name: String = "feature",
        head: String = "ref: refs/heads/worktree-feature\n",
        commondir: String = "../..\n",
        backReferenceOverride: String? = nil
    ) throws -> (repo: String, worktree: String) {
        let repoURL = root.appendingPathComponent(repo)
        let worktreeURL = repoURL
            .appendingPathComponent(".claude/worktrees").appendingPathComponent(name)
        let gitdirURL = repoURL.appendingPathComponent(".git/worktrees").appendingPathComponent(name)

        try write("gitdir: \(gitdirURL.path)\n", to: worktreeURL.appendingPathComponent(".git"))
        try write(
            backReferenceOverride ?? "\(worktreeURL.path)/.git\n",
            to: gitdirURL.appendingPathComponent("gitdir")
        )
        try write(commondir, to: gitdirURL.appendingPathComponent("commondir"))
        try write(head, to: gitdirURL.appendingPathComponent("HEAD"))

        try write("ref: refs/heads/main\n", to: repoURL.appendingPathComponent(".git/HEAD"))

        return (repoURL.path, worktreeURL.path)
    }

    func testALinkedWorktreeResolvesToTheRepositoryItCameFrom() throws {
        let (repo, worktree) = try makeWorktree()
        let origin = WorktreeIndex.resolve(worktree)
        XCTAssertEqual(origin?.path, repo)
        XCTAssertEqual(origin?.branch, "worktree-feature")
    }

    func testAnOrdinaryRepositoryResolvesToNil() throws {
        let (repo, _) = try makeWorktree()
        XCTAssertNil(WorktreeIndex.resolve(repo))
    }

    func testADirectoryThatIsNotARepositoryResolvesToNil() {
        XCTAssertNil(WorktreeIndex.resolve(root.appendingPathComponent("nowhere").path))
    }

    func testARelativeGitdirPointerResolves() throws {
        let (repo, worktree) = try makeWorktree()
        try write(
            "gitdir: ../../../.git/worktrees/feature\n",
            to: URL(fileURLWithPath: worktree).appendingPathComponent(".git")
        )
        XCTAssertEqual(WorktreeIndex.resolve(worktree)?.path, repo)
    }

    func testAStaleBackReferenceResolvesToNil() throws {
        let (_, worktree) = try makeWorktree(backReferenceOverride: "/somewhere/else/.git\n")
        XCTAssertNil(WorktreeIndex.resolve(worktree))
    }

    func testAGitDirectoryOutsideAWorkingTreeResolvesToNil() throws {
        let elsewhere = root.appendingPathComponent("elsewhere/gitdir").path
        let (_, worktree) = try makeWorktree(commondir: "\(elsewhere)\n")
        XCTAssertNil(WorktreeIndex.resolve(worktree))
    }

    func testADetachedHeadStillResolvesTheProject() throws {
        let (repo, worktree) = try makeWorktree(head: "9f4c2b1a9f4c2b1a9f4c2b1a9f4c2b1a9f4c2b1a\n")
        let origin = WorktreeIndex.resolve(worktree)
        XCTAssertEqual(origin?.path, repo)
        XCTAssertNil(origin?.branch)
    }

    func testTheRepositoryStillResolvesAfterTheWorktreeIsDeleted() throws {
        let (repo, worktree) = try makeWorktree()
        let index = WorktreeIndex()
        XCTAssertEqual(index.origin(of: worktree)?.path, repo)

        try FileManager.default.removeItem(at: URL(fileURLWithPath: worktree))
        XCTAssertEqual(index.origin(of: worktree)?.path, repo)
        XCTAssertNil(WorktreeIndex.resolve(worktree), "with no cache, the link is gone")
    }

    func testLinkFileParsingIgnoresAnythingThatIsNotAGitdirPointer() {
        XCTAssertNil(WorktreeLink.gitdirPointer(inLinkFile: "", relativeTo: "/repo"))
        XCTAssertNil(WorktreeLink.gitdirPointer(inLinkFile: "gitdir:\n", relativeTo: "/repo"))
        XCTAssertNil(WorktreeLink.gitdirPointer(inLinkFile: "ref: refs/heads/x", relativeTo: "/repo"))
        XCTAssertEqual(
            WorktreeLink.gitdirPointer(inLinkFile: "gitdir: /a/.git/worktrees/b\n", relativeTo: "/repo"),
            "/a/.git/worktrees/b"
        )
    }

    func testRepositoryIsOnlyDerivedFromAConventionalGitDirectory() {
        XCTAssertEqual(WorktreeLink.repository(forCommonDirectory: "/Users/e/repo/.git"), "/Users/e/repo")
        XCTAssertNil(WorktreeLink.repository(forCommonDirectory: "/Users/e/bare.git"))
        XCTAssertNil(WorktreeLink.repository(forCommonDirectory: "/"))
    }

    func testBranchParsing() {
        XCTAssertEqual(WorktreeLink.branch(fromHEAD: "ref: refs/heads/feature/x\n"), "feature/x")
        XCTAssertNil(WorktreeLink.branch(fromHEAD: "9f4c2b1a\n"))
        XCTAssertNil(WorktreeLink.branch(fromHEAD: ""))
    }

    private func makeRowJoined(
        _ name: String,
        cwd: String,
        index: WorktreeIndex,
        state: HostSessionState = .running
    ) -> SessionRowModel {
        SessionRowModel(
            session: makeSession(name, state: state, cwd: cwd),
            worktree: index.origin(of: cwd)
        )
    }

    func testASessionDispatchedInsideAWorktreeGroupsUnderTheRepository() throws {
        let (repo, worktree) = try makeWorktree()
        let index = WorktreeIndex()

        let rows = [
            makeRowJoined("in-repo", cwd: repo, index: index),
            makeRowJoined("in-worktree", cwd: worktree, index: index),
        ]

        let isolated = try XCTUnwrap(rows.first { $0.session.cwd == worktree })
        XCTAssertEqual(isolated.projectPath, repo)
        XCTAssertNotNil(isolated.worktree)
        XCTAssertEqual(isolated.worktreeBranch, "worktree-feature")

        let summaries = ProjectIndex.summaries(for: rows)
        XCTAssertEqual(summaries.count, 1, "the worktree must not become its own project")
        XCTAssertEqual(summaries[0].path, repo)
        XCTAssertEqual(summaries[0].total, 2)
    }

    func testASessionSurvivesItsWorktreeBeingReaped() throws {
        let (repo, worktree) = try makeWorktree()
        let index = WorktreeIndex()

        XCTAssertEqual(makeRowJoined("x", cwd: worktree, index: index).projectPath, repo)
        try FileManager.default.removeItem(at: URL(fileURLWithPath: worktree))

        XCTAssertEqual(makeRowJoined("x", cwd: worktree, index: index).projectPath, repo,
                       "the cached origin outlives the worktree on disk")
    }

    func testBuildingRowsNeverAsksGitForMergeState() throws {
        let (_, worktree) = try makeWorktree()
        let probe = ScriptedGit()

        let row = makeRowJoined("x", cwd: worktree, index: WorktreeIndex(), state: .done)
        XCTAssertTrue(MergeStateResolver.isEligible(row), "otherwise the assertion below is vacuous")
        XCTAssertNil(row.mergeStatus)
        XCTAssertTrue(probe.calls.isEmpty, "publishing the rows must cost no git calls")

        _ = MergeStateResolver.resolve(rows: [row], probe: probe)
        XCTAssertFalse(probe.calls.isEmpty, "the merge pass runs later, not here")
    }

    func testAnOrdinarySessionIsUnaffectedByTheGitRead() throws {
        let (repo, _) = try makeWorktree()

        let row = makeRowJoined("plain", cwd: repo, index: WorktreeIndex())
        XCTAssertEqual(row.projectPath, repo)
        XCTAssertNil(row.worktree)
        XCTAssertNil(row.worktreeBranch)
    }
}
