import XCTest
@testable import DexCore

final class ScriptedGit: GitProbe, WorktreeRemover, @unchecked Sendable {
    var branchesByRepository: [String: [String]] = [:]
    var mergedByRepository: [String: [String]] = [:]
    var mergedByBase: [String: [String]] = [:]
    var outstandingByBranch: [String: Int] = [:]
    var outstandingByBase: [String: Int] = [:]
    var originHeadByRepository: [String: String] = [:]
    var headByRepository: [String: String] = [:]
    var dirtyByWorktree: [String: Int] = [:]
    var commonDirectoryByRepository: [String: String] = [:]
    var movedByBranch: [String: Bool] = [:]
    var everyBranchMoved = true

    private let lock = NSLock()
    private var recorded: [String] = []

    var calls: [String] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    private func record(_ call: String) {
        lock.lock()
        recorded.append(call)
        lock.unlock()
    }

    func count(of prefix: String) -> Int {
        calls.filter { $0.hasPrefix(prefix) }.count
    }

    func branches(inRepository repository: String) -> [String]? {
        record("branches:\(repository)")
        return branchesByRepository[repository]
    }

    func branches(inRepository repository: String, mergedInto base: String) -> [String]? {
        record("merged:\(repository):\(base)")
        return mergedByBase["\(repository)|\(base)"] ?? mergedByRepository[repository]
    }

    func outstandingCommitCount(base: String, branch: String, inRepository repository: String) -> Int? {
        record("cherry:\(repository):\(branch)@\(base)")
        return outstandingByBase["\(base)|\(branch)"] ?? outstandingByBranch[branch]
    }

    func symbolicRefTarget(_ ref: String, inRepository repository: String) -> String? {
        record("symbolic:\(repository):\(ref)")
        return ref == "HEAD" ? headByRepository[repository] : originHeadByRepository[repository]
    }

    func headBranch(inRepository repository: String) -> String? {
        symbolicRefTarget("HEAD", inRepository: repository)
    }

    func uncommittedFileCount(inWorktree path: String) -> Int? {
        record("status:\(path)")
        return dirtyByWorktree[path]
    }

    func commonDirectory(inRepository repository: String) -> String? {
        record("common:\(repository)")
        return commonDirectoryByRepository[repository]
    }

    func branchMoved(sinceCreationOf branch: String, inRepository repository: String) -> Bool? {
        record("reflog:\(repository):\(branch)")
        return movedByBranch[branch] ?? (everyBranchMoved ? true : nil)
    }

    var removalSucceeds = true

    var removedWorktrees: [String] {
        calls.filter { $0.hasPrefix("remove:") }.map { String($0.split(separator: "|").last!) }
    }

    func removeWorktree(at path: String, inRepository repository: String) -> Bool {
        record("remove:\(repository)|\(path)")
        return removalSucceeds
    }
}

private func makeFinishedWorktreeRow(
    _ name: String,
    repository: String,
    branch: String,
    worktree: String,
    state: HostSessionState = .done
) -> SessionRowModel {
    makeRow(
        name,
        state: state,
        cwd: worktree,
        worktree: WorktreeOrigin(path: repository, branch: branch)
    )
}

final class BaseBranchTests: XCTestCase {
    func testPrefersOriginHeadWhenTheLocalBranchExists() {
        XCTAssertEqual(
            MergeState.baseBranch(
                originHead: "origin/develop",
                branches: ["develop", "main", "feature"],
                checkedOutBranch: "feature"
            ),
            "develop",
            "origin/HEAD is the only candidate the repository actually declares"
        )
    }

    func testIgnoresOriginHeadWithNoLocalBranch() {
        XCTAssertEqual(
            MergeState.baseBranch(
                originHead: "origin/develop",
                branches: ["main", "feature"],
                checkedOutBranch: "feature"
            ),
            "main"
        )
    }

    func testFallsBackToMainThenMaster() {
        XCTAssertEqual(
            MergeState.baseBranch(originHead: nil, branches: ["master", "main"], checkedOutBranch: nil),
            "main",
            "main wins over master when a repo somehow has both"
        )
        XCTAssertEqual(
            MergeState.baseBranch(originHead: nil, branches: ["master", "topic"], checkedOutBranch: nil),
            "master"
        )
    }

    func testFallsBackToTheCheckedOutBranch() {
        XCTAssertEqual(
            MergeState.baseBranch(originHead: nil, branches: ["trunk", "topic"], checkedOutBranch: "trunk"),
            "trunk"
        )
    }

    func testCheckedOutBranchIsNotConsultedWhenAConventionalTrunkExists() {
        var consulted = false
        let base = MergeState.baseBranch(
            originHead: nil,
            branches: ["main", "topic"],
            checkedOutBranch: {
                consulted = true
                return "topic"
            }()
        )
        XCTAssertEqual(base, "main")
        XCTAssertFalse(consulted, "the autoclosure keeps this git call unevaluated")
    }

    func testNoAnswerWhenTheBaseCannotBeResolved() {
        XCTAssertNil(
            MergeState.baseBranch(originHead: nil, branches: ["topic-a", "topic-b"], checkedOutBranch: nil),
            "nothing resolved — that must render as no badge, not as a default"
        )
        XCTAssertNil(
            MergeState.baseBranch(originHead: nil, branches: [], checkedOutBranch: "main"),
            "a detached or empty repo has nothing to compare against"
        )
    }
}

final class CherryParsingTests: XCTestCase {
    func testCountsOnlyPlusLines() {
        let output = """
        + 03d3f916f0029dc761903e9eac97e03ab0378845
        - 8910040e451cac2dcf65bc7aad0eebde45dfaa40
        + 937bce4f4c630c3f470d0f751007c3548b3bd3ab
        """
        XCTAssertEqual(MergeState.outstandingCommits(inCherryOutput: output), 2)
    }

    func testAllMinusLinesMeansNothingOutstanding() {
        let output = "- 8910040e451cac2dcf65bc7aad0eebde45dfaa40\n"
        XCTAssertEqual(MergeState.outstandingCommits(inCherryOutput: output), 0)
    }

    func testEmptyOutput() {
        XCTAssertEqual(MergeState.outstandingCommits(inCherryOutput: ""), 0)
        XCTAssertEqual(MergeState.outstandingCommits(inCherryOutput: "\n\n"), 0)
    }
}

final class BranchMergeStateTests: XCTestCase {
    func testAncestryShortCircuitsWithoutThePatchIdCall() {
        var asked = false
        let state = MergeState.mergeState(
            branch: "feature",
            existingBranches: ["feature", "main"],
            mergedBranches: ["feature", "main"],
            outstandingCommits: {
                asked = true
                return 0
            }
        )
        XCTAssertEqual(state, .merged)
        XCTAssertFalse(asked, "ancestry resolved it, so git cherry must not run")
    }

    func testPatchEquivalentCommitsReadAsMerged() {
        let state = MergeState.mergeState(
            branch: "rebased",
            existingBranches: ["rebased", "main"],
            mergedBranches: ["main"],
            outstandingCommits: { 0 }
        )
        XCTAssertEqual(state, .merged, "landed by rebase or cherry-pick")
    }

    func testOutstandingCarriesTheCount() {
        let state = MergeState.mergeState(
            branch: "open",
            existingBranches: ["open", "main"],
            mergedBranches: ["main"],
            outstandingCommits: { 3 }
        )
        XCTAssertEqual(state, .outstanding(commits: 3))
        XCTAssertTrue(state?.hasOutstandingCommits == true)
    }

    func testMissingBranchIsItsOwnCase() {
        let state = MergeState.mergeState(
            branch: "reaped",
            existingBranches: ["main"],
            mergedBranches: ["main"],
            outstandingCommits: { XCTFail("must not ask git about a branch that isn't there"); return 0 }
        )
        XCTAssertEqual(state, .branchGone)
        XCTAssertFalse(state?.hasOutstandingCommits == true)
    }

    func testUnresolvableStaysNil() {
        XCTAssertNil(
            MergeState.mergeState(
                branch: "feature",
                existingBranches: ["feature", "main"],
                mergedBranches: ["main"],
                outstandingCommits: { nil }
            ),
            "git could not answer — that is no badge, never a guess"
        )
    }
}

final class MergeAttentionTests: XCTestCase {
    func testMergedAndCleanNeedsNoAttention() {
        let status = WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 0)
        XCTAssertFalse(status.needsAttention)
    }

    func testOutstandingCommitsNeedAttention() {
        XCTAssertTrue(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 2), uncommittedFiles: 0)
                .needsAttention
        )
    }

    func testMergedButDirtyNeedsAttention() {
        XCTAssertTrue(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 8).needsAttention
        )
    }

    func testAReapedWorktreeIsNotDirty() {
        let status = WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: nil)
        XCTAssertFalse(
            status.needsAttention,
            "nil is 'no worktree to look at', which must not read as unsaved work"
        )
    }

    func testBranchGoneNeedsNoAttention() {
        XCTAssertFalse(
            WorktreeMergeStatus(base: "main", merge: .branchGone, uncommittedFiles: nil).needsAttention
        )
    }
}

final class MergeEligibilityTests: XCTestCase {

    func testFinishedWorktreeSessionIsEligible() {
        let row = makeFinishedWorktreeRow(
            "landed",
            repository: "/repo",
            branch: "worktree-feature",
            worktree: "/repo/.claude/worktrees/feature"
        )
        XCTAssertNotNil(row.worktree)
        XCTAssertTrue(MergeStateResolver.isEligible(row), "the branch is the key the query needs")
    }

    func testWorkInFlightIsNotEligible() {
        for state in [HostSessionState.running, .asking] {
            let row = makeFinishedWorktreeRow(
                "busy",
                repository: "/repo",
                branch: "worktree-feature",
                worktree: "/repo/.claude/worktrees/feature",
                state: state
            )
            XCTAssertFalse(
                MergeStateResolver.isEligible(row),
                "\(state.raw): unmerged is the expected state, so saying it adds nothing"
            )
        }
    }

    func testStoppedAndFailedAreEligible() {
        for state in [HostSessionState.idle, .failed] {
            let row = makeFinishedWorktreeRow(
                "over",
                repository: "/repo",
                branch: "worktree-feature",
                worktree: "/repo/.claude/worktrees/feature",
                state: state
            )
            XCTAssertTrue(
                MergeStateResolver.isEligible(row),
                "\(state.raw) is over, and 'failed' is recoverable — both are worth knowing about"
            )
        }
    }

    func testUnknownStateIsNeverInferredToBeFinished() {
        let row = makeFinishedWorktreeRow(
            "future",
            repository: "/repo",
            branch: "worktree-feature",
            worktree: "/repo/.claude/worktrees/feature",
            state: .unknown("quiesced")
        )
        XCTAssertFalse(MergeStateResolver.isEligible(row))
    }

    func testASessionWithNoBranchIsNotEligible() {
        XCTAssertFalse(MergeStateResolver.isEligible(makeRow("plain", state: .done)))
    }
}

final class MergeStateResolverTests: XCTestCase {
    private func git(repository: String = "/repo") -> ScriptedGit {
        let git = ScriptedGit()
        git.branchesByRepository[repository] = ["main", "worktree-a", "worktree-b"]
        git.mergedByRepository[repository] = ["main", "worktree-a"]
        git.outstandingByBranch["worktree-b"] = 2
        return git
    }

    func testResolvesMergedAndOutstandingTogether() {
        let rows = [
            makeFinishedWorktreeRow("a", repository: "/repo", branch: "worktree-a", worktree: "/wt/a"),
            makeFinishedWorktreeRow("b", repository: "/repo", branch: "worktree-b", worktree: "/wt/b"),
        ]
        let probe = git()
        probe.dirtyByWorktree = ["/wt/a": 0, "/wt/b": 3]

        let byRow = MergeStateResolver.resolve(rows: rows, probe: probe)

        XCTAssertEqual(byRow[rows[0].rowID]?.merge, .merged)
        XCTAssertEqual(byRow[rows[0].rowID]?.uncommittedFiles, 0)
        XCTAssertEqual(byRow[rows[0].rowID]?.base, "main")
        XCTAssertFalse(byRow[rows[0].rowID]!.needsAttention)

        XCTAssertEqual(byRow[rows[1].rowID]?.merge, .outstanding(commits: 2))
        XCTAssertEqual(byRow[rows[1].rowID]?.uncommittedFiles, 3)
        XCTAssertTrue(byRow[rows[1].rowID]!.needsAttention)
    }

    func testRepositoryAndBranchReadsAreMadeOncePerDistinctKey() {
        let rows = (1...5).map {
            makeFinishedWorktreeRow("b\($0)", repository: "/repo", branch: "worktree-b", worktree: "/wt/b")
        }
        let probe = git()
        probe.dirtyByWorktree = ["/wt/b": 1]

        _ = MergeStateResolver.resolve(rows: rows, probe: probe)

        XCTAssertEqual(probe.count(of: "branches:"), 1, "one branch list per repository, not per row")
        XCTAssertEqual(probe.count(of: "merged:"), 1)
        XCTAssertEqual(probe.count(of: "cherry:"), 1, "one patch-id call per branch, not per row")
        XCTAssertEqual(probe.count(of: "status:"), 1, "one status per worktree, not per row")
    }

    func testIneligibleRowsCostNoGitCalls() {
        let probe = git()
        let rows = [
            makeRow("plain", state: .done),
            makeFinishedWorktreeRow("busy", repository: "/repo", branch: "worktree-b",
                                    worktree: "/wt/b", state: .running),
        ]
        XCTAssertTrue(MergeStateResolver.resolve(rows: rows, probe: probe).isEmpty)
        XCTAssertTrue(probe.calls.isEmpty, "no worktree branch and no finished work, so no git call")
    }

    func testUnreadableRepositoryYieldsNoStatus() {
        let probe = ScriptedGit()
        let rows = [
            makeFinishedWorktreeRow("a", repository: "/not-a-repo", branch: "worktree-a", worktree: "/wt/a")
        ]
        XCTAssertTrue(MergeStateResolver.resolve(rows: rows, probe: probe).isEmpty)
    }

    func testOneUnreadableRepositoryDoesNotSuppressAnother() {
        let probe = git(repository: "/repo")
        probe.dirtyByWorktree = ["/wt/a": 0]
        let rows = [
            makeFinishedWorktreeRow("bad", repository: "/gone", branch: "worktree-x", worktree: "/wt/x"),
            makeFinishedWorktreeRow("good", repository: "/repo", branch: "worktree-a", worktree: "/wt/a"),
        ]
        let byRow = MergeStateResolver.resolve(rows: rows, probe: probe)
        XCTAssertNil(byRow[rows[0].rowID])
        XCTAssertEqual(byRow[rows[1].rowID]?.merge, .merged)
    }

    func testReapedWorktreeStillResolvesItsBranch() {
        let probe = git()
        probe.dirtyByWorktree = [:]
        let rows = [
            makeFinishedWorktreeRow("a", repository: "/repo", branch: "worktree-a", worktree: "/wt/gone")
        ]
        let status = MergeStateResolver.resolve(rows: rows, probe: probe)[rows[0].rowID]
        XCTAssertEqual(status?.merge, .merged)
        XCTAssertNil(status?.uncommittedFiles)
    }

    func testBranchDeletedAfterMerge() {
        let probe = git()
        probe.dirtyByWorktree = ["/wt/z": 0]
        let rows = [
            makeFinishedWorktreeRow("z", repository: "/repo", branch: "worktree-z", worktree: "/wt/z")
        ]
        XCTAssertEqual(
            MergeStateResolver.resolve(rows: rows, probe: probe)[rows[0].rowID]?.merge,
            .branchGone
        )
        XCTAssertEqual(probe.count(of: "cherry:"), 0)
    }

    func testAnswersAreUnchangedWhenTheCallsOverlap() {
        let probe = ScriptedGit()
        for repository in ["/repo-a", "/repo-b"] {
            probe.branchesByRepository[repository] = ["main", "landed", "rebased", "outstanding"]
            probe.mergedByRepository[repository] = ["main", "landed"]
        }
        probe.outstandingByBranch["rebased"] = 0
        probe.outstandingByBranch["outstanding"] = 3

        var rows: [SessionRowModel] = []
        for repository in ["/repo-a", "/repo-b"] {
            for branch in ["landed", "rebased", "outstanding", "gone"] {
                for index in 0..<5 {
                    let worktree = "\(repository)/wt/\(branch)-\(index)"
                    probe.dirtyByWorktree[worktree] = index
                    rows.append(makeFinishedWorktreeRow(
                        "\(repository)-\(branch)-\(index)",
                        repository: repository, branch: branch, worktree: worktree
                    ))
                }
            }
        }

        let byRow = MergeStateResolver.resolve(rows: rows, probe: probe)

        XCTAssertEqual(byRow.count, rows.count)
        for row in rows {
            let status = byRow[row.rowID]
            switch row.worktreeBranch {
            case "landed", "rebased": XCTAssertEqual(status?.merge, .merged, row.rowID)
            case "outstanding": XCTAssertEqual(status?.merge, .outstanding(commits: 3), row.rowID)
            default: XCTAssertEqual(status?.merge, .branchGone, row.rowID)
            }
            XCTAssertEqual(status?.uncommittedFiles,
                           row.worktreePath.flatMap { probe.dirtyByWorktree[$0] },
                           row.rowID)
        }

        XCTAssertEqual(probe.count(of: "branches:"), 2, "one per repository")
        XCTAssertEqual(probe.count(of: "cherry:"), 4, "one per branch ancestry could not resolve")
        XCTAssertEqual(probe.count(of: "status:"), 40, "one per worktree")
    }

    func testEachAnswerIsKeyedToItsOwnBranch() {
        let probe = ScriptedGit()
        probe.branchesByRepository["/repo"] = ["main", "one", "two", "three", "four"]
        probe.mergedByRepository["/repo"] = ["main"]
        probe.outstandingByBranch = ["one": 1, "two": 2, "three": 3, "four": 4]

        let rows = ["one", "two", "three", "four"].map {
            makeFinishedWorktreeRow($0, repository: "/repo", branch: $0, worktree: "/wt/\($0)")
        }
        let byRow = MergeStateResolver.resolve(rows: rows, probe: probe)

        for (expected, row) in zip([1, 2, 3, 4], rows) {
            XCTAssertEqual(byRow[row.rowID]?.merge, .outstanding(commits: expected), row.rowID)
        }
    }
}

private struct TestRepository {
    let url: URL
    var path: String { url.path }

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("merge-state-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        git("init", "-q", "-b", "main", ".")
        git("config", "user.email", "tests@example.com")
        git("config", "user.name", "Tests")
        commit("base.txt", "base", as: "base")
    }

    func git(_ arguments: String...) {
        _ = try? Shell.run(["git", "-C", path] + arguments)
    }

    func write(_ name: String, _ contents: String) {
        try? contents.write(to: url.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func commit(_ name: String, _ contents: String, as message: String) {
        write(name, contents)
        git("add", ".")
        git("commit", "-qm", message)
    }

    func branch(_ name: String) {
        git("checkout", "-qb", name, "main")
    }

    func discard() {
        try? FileManager.default.removeItem(at: url)
    }
}

final class BuildInclusionTests: XCTestCase {

    private let built = "0f2b8c1d4e6a7b9c0d1e2f3a4b5c6d7e8f9a0b1c"
    private var build: RunningBuild { RunningBuild(commit: built, checkoutRoot: "/app") }

    /// One repository the app was built out of, one it was not, both holding a
    /// branch that landed — only the first can say anything about the build.
    private func git() -> ScriptedGit {
        let probe = ScriptedGit()
        for repository in ["/app", "/app/.claude/worktrees/w", "/other"] {
            probe.branchesByRepository[repository] = ["main", "landed", "since", "rebased", "open"]
            probe.mergedByRepository[repository] = ["main", "landed", "since"]
            probe.commonDirectoryByRepository[repository] =
                repository == "/other" ? "/other/.git" : "/app/.git"
        }

        // The built commit is behind main: it has `landed`, not `since`.
        for repository in ["/app", "/app/.claude/worktrees/w", "/other"] {
            probe.mergedByBase["\(repository)|\(built)"] = ["landed"]
        }
        probe.outstandingByBranch = ["rebased": 0, "open": 3]
        probe.outstandingByBase["\(built)|rebased"] = 0
        return probe
    }

    private func row(_ branch: String, repository: String = "/app") -> SessionRowModel {
        makeFinishedWorktreeRow(
            "\(repository)-\(branch)", repository: repository, branch: branch, worktree: "/wt/\(branch)"
        )
    }

    private func resolve(
        _ rows: [SessionRowModel],
        probe: ScriptedGit,
        build: RunningBuild?
    ) -> [String: WorktreeMergeStatus] {
        MergeStateResolver.resolve(rows: rows, probe: probe, runningBuild: build)
    }

    func testABranchTheBuiltCommitContainsIsInTheBuild() {
        let rows = [row("landed")]
        let status = resolve(rows, probe: git(), build: build)[rows[0].rowID]
        XCTAssertEqual(status?.build, .inBuild)
        XCTAssertFalse(status!.isNotable, "landed and running is the quiet end of a session")
    }

    func testABranchThatLandedAfterTheBuildAwaitsARestart() {
        let rows = [row("since")]
        let status = resolve(rows, probe: git(), build: build)[rows[0].rowID]
        XCTAssertEqual(status?.merge, .merged, "it is in main — the build is what's behind")
        XCTAssertEqual(status?.build, .awaitingRestart)
        XCTAssertTrue(status!.isNotable)
        XCTAssertEqual(status?.label, "not in this build")
    }

    func testAnotherRepositoryIsNeverToldAboutThisBuild() {
        let rows = [row("since", repository: "/other")]
        let status = resolve(rows, probe: git(), build: build)[rows[0].rowID]
        XCTAssertEqual(status?.merge, .merged)
        XCTAssertNil(status?.build, "a different repository has no bearing on what this app runs")
        XCTAssertFalse(status!.isNotable)
    }

    func testAWorktreeOfTheSameRepositoryIsRecognisedByItsCommonDirectory() {
        let rows = [row("since", repository: "/app/.claude/worktrees/w")]
        XCTAssertEqual(
            resolve(rows, probe: git(), build: build)[rows[0].rowID]?.build,
            .awaitingRestart,
            "the path differs from the checkout root, the repository does not"
        )
    }

    func testWithNoStampNothingIsClaimedAndNothingIsAsked() {
        let probe = git()
        let rows = [row("landed"), row("since")]
        let byRow = resolve(rows, probe: probe, build: nil)

        XCTAssertEqual(byRow[rows[0].rowID]?.merge, .merged)
        XCTAssertNil(byRow[rows[0].rowID]?.build)
        XCTAssertNil(byRow[rows[1].rowID]?.build)
        XCTAssertEqual(probe.count(of: "common:"), 0, "no build to compare against, so no extra call")
        XCTAssertEqual(probe.count(of: "merged:"), 1, "one ancestry read, against main only")
    }

    func testAnUnreadableCheckoutMakesTheWholePassBuildBlind() {
        let probe = git()
        probe.commonDirectoryByRepository["/app"] = nil
        let rows = [row("since")]
        XCTAssertNil(resolve(rows, probe: probe, build: build)[rows[0].rowID]?.build)
    }

    func testABranchLandedByRebaseIsNotReportedMissingForever() {
        let probe = git()
        let rows = [row("rebased")]
        let status = resolve(rows, probe: probe, build: build)[rows[0].rowID]

        XCTAssertEqual(status?.merge, .merged, "patch-equivalent, so it landed")
        XCTAssertEqual(
            status?.build, .inBuild,
            "it is no ancestor of the built commit either — ancestry alone would never clear"
        )
        XCTAssertEqual(probe.count(of: "cherry:/app:rebased@\(built)"), 1)
    }

    func testASessionThatCommittedNothingIsNotWorkTheBuildIsMissing() {
        let probe = git()
        probe.movedByBranch["since"] = false

        let rows = [row("since")]
        let status = resolve(rows, probe: probe, build: build)[rows[0].rowID]

        XCTAssertEqual(status?.merge, .merged, "its tip is a main commit, so ancestry says landed")
        XCTAssertEqual(
            status?.build, .inBuild,
            "the branch never moved off what it was cut from — there is no work to be missing"
        )
        XCTAssertFalse(status!.isNotable, "and nothing to say about restarting for it")
    }

    func testWithNothingRecordingTheBranchTheAncestryStands() {
        let probe = git()
        probe.everyBranchMoved = false

        let rows = [row("since")]
        XCTAssertEqual(
            resolve(rows, probe: probe, build: build)[rows[0].rowID]?.build,
            .awaitingRestart,
            "no reflog is not evidence of an empty branch"
        )
    }

    func testUnlandedWorkIsNotAskedAboutTheBuild() {
        let probe = git()
        let rows = [row("open")]
        let status = resolve(rows, probe: probe, build: build)[rows[0].rowID]

        XCTAssertEqual(status?.merge, .outstanding(commits: 3))
        XCTAssertNil(status?.build, "it isn't in main either — the build is not the story")
        XCTAssertEqual(probe.count(of: "cherry:/app:open@\(built)"), 0)
    }

    func testAGoneBranchClaimsNothingAboutTheBuild() {
        let probe = git()
        let rows = [row("reaped")]
        let status = resolve(rows, probe: probe, build: build)[rows[0].rowID]

        XCTAssertEqual(status?.merge, .branchGone)
        XCTAssertNil(status?.build)
    }

    func testTheBuildIsReadOncePerRepositoryAndOncePerBranchAtMost() {
        let probe = git()
        let rows = (1...4).map { _ in row("since") } + (1...3).map { _ in row("landed") }
        _ = resolve(rows, probe: probe, build: build)

        XCTAssertEqual(probe.count(of: "merged:/app:\(built)"), 1)
        XCTAssertEqual(probe.count(of: "reflog:/app:since"), 1, "one per branch, not per row")
        XCTAssertEqual(
            probe.count(of: "reflog:/app:landed"), 0,
            "the build already has it, so nothing more is worth asking"
        )
        XCTAssertEqual(
            probe.count(of: "cherry:/app:since@\(built)"), 0,
            "ancestry said it landed, so ancestry settles the build — no patch-id call"
        )
    }
}

final class CommonDirectoryTests: XCTestCase {

    func testARelativeAnswerIsReadAgainstTheDirectoryItWasAskedIn() {
        XCTAssertEqual(
            MergeState.commonDirectory(inOutput: ".git\n", repository: "/repo"),
            "/repo/.git",
            "git answers relatively from the top of the main worktree"
        )
    }

    func testAnAbsoluteAnswerIsKept() {
        XCTAssertEqual(
            MergeState.commonDirectory(inOutput: "/repo/.git\n", repository: "/repo/.claude/worktrees/w"),
            "/repo/.git",
            "a linked worktree answers with the repository it belongs to"
        )
    }

    func testBothSidesOfTheComparisonResolveTheSameWay() {
        XCTAssertEqual(
            MergeState.commonDirectory(inOutput: ".git", repository: "/repo/./sub/.."),
            MergeState.commonDirectory(inOutput: "/repo/.git", repository: "/elsewhere")
        )
    }

    func testNoAnswerIsNoAnswer() {
        XCTAssertNil(MergeState.commonDirectory(inOutput: "", repository: "/repo"))
        XCTAssertNil(MergeState.commonDirectory(inOutput: "\n  \n", repository: "/repo"))
    }
}

final class BranchMovementTests: XCTestCase {

    func testOneEntryIsABranchThatWasCreatedAndLeftAlone() {
        XCTAssertEqual(
            MergeState.moved(inReflogOutput: "25534b3 w@{0}: branch: Created from main\n"),
            false
        )
    }

    func testAnythingAfterThatIsWorkOfItsOwn() {
        let output = """
        9c1e0a2 w@{0}: commit: Say it plainly
        25534b3 w@{1}: branch: Created from main
        """
        XCTAssertEqual(MergeState.moved(inReflogOutput: output), true)
    }

    func testNothingRecordedIsNotTheSameAsNeverMoved() {
        XCTAssertNil(
            MergeState.moved(inReflogOutput: ""),
            "reflogs can be off or expired, and that must not read as an empty branch"
        )
        XCTAssertNil(MergeState.moved(inReflogOutput: "\n \n"))
    }
}

final class RealGitTests: XCTestCase {

    nonisolated(unsafe) private static var shared: URL?

    override class func tearDown() {
        if let shared { try? FileManager.default.removeItem(at: shared) }
        shared = nil
        super.tearDown()
    }

    private var repository: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(Self.gitIsAvailable, "git not on PATH")
        if Self.shared == nil { Self.shared = try Self.makeRepository() }
        repository = Self.shared
    }

    private static func makeRepository() throws -> URL {
        let repository = try TestRepository()

        repository.branch("fast-forward")
        repository.commit("ff.txt", "ff", as: "ff")

        repository.branch("squashed")
        repository.commit("squash.txt", "one", as: "squash one")
        repository.commit("squash.txt", "two", as: "squash two")

        repository.branch("rebased")
        repository.commit("rebase.txt", "r", as: "rebased work")

        repository.branch("open")
        repository.commit("open.txt", "o", as: "open work")

        repository.git("checkout", "-q", "main")
        repository.git("merge", "-q", "--ff-only", "fast-forward")
        repository.git("merge", "-q", "--squash", "squashed")
        repository.git("commit", "-qm", "squashed in")
        repository.git("cherry-pick", "rebased")

        return repository.url
    }

    private var probe: GitCommandProbe { GitCommandProbe() }

    private func state(of branch: String, in repository: URL? = nil) -> BranchMergeState? {
        let path = (repository ?? self.repository).path
        let all = Set(probe.branches(inRepository: path) ?? [])
        let merged = Set(probe.branches(inRepository: path, mergedInto: "main") ?? [])
        return MergeState.mergeState(
            branch: branch,
            existingBranches: all,
            mergedBranches: merged,
            outstandingCommits: {
                probe.outstandingCommitCount(base: "main", branch: branch, inRepository: path)
            }
        )
    }

    func testFastForwardedBranchReadsAsMerged() {
        XCTAssertEqual(state(of: "fast-forward"), .merged)
    }

    func testRebasedBranchReadsAsMergedDespiteNotBeingAnAncestor() {
        let merged = Set(probe.branches(inRepository: repository.path, mergedInto: "main") ?? [])
        XCTAssertFalse(merged.contains("rebased"), "not an ancestor, so ancestry alone would report it outstanding")
        XCTAssertEqual(state(of: "rebased"), .merged)
    }

    func testUnlandedBranchReportsItsCommits() {
        XCTAssertEqual(state(of: "open"), .outstanding(commits: 1))
    }

    func testSquashMergedBranchIsIndistinguishableFromUnmerged() {
        XCTAssertEqual(
            state(of: "squashed"),
            .outstanding(commits: 2),
            "no read of the repository ties two commits to the one that squashed them"
        )
    }

    func testDeletedBranchReadsAsGone() throws {
        let own = try TestRepository()
        defer { own.discard() }
        own.branch("open")
        own.commit("open.txt", "o", as: "open work")
        own.git("checkout", "-q", "main")

        XCTAssertEqual(state(of: "open", in: own.url), .outstanding(commits: 1))
        own.git("branch", "-D", "open")
        XCTAssertEqual(state(of: "open", in: own.url), .branchGone)
    }

    func testBaseBranchResolvesToMainWithNoRemote() {
        XCTAssertNil(
            probe.symbolicRefTarget("refs/remotes/origin/HEAD", inRepository: repository.path),
            "no remote is the normal case for this repo's own projects, and must not be an error"
        )
        XCTAssertEqual(
            MergeState.baseBranch(
                originHead: probe.symbolicRefTarget("refs/remotes/origin/HEAD", inRepository: repository.path),
                branches: probe.branches(inRepository: repository.path) ?? [],
                checkedOutBranch: probe.headBranch(inRepository: repository.path)
            ),
            "main"
        )
    }

    func testUncommittedFilesCountsTrackedAndUntracked() throws {
        let own = try TestRepository()
        defer { own.discard() }

        XCTAssertEqual(probe.uncommittedFileCount(inWorktree: own.path), 0)

        own.write("base.txt", "edited")
        XCTAssertEqual(probe.uncommittedFileCount(inWorktree: own.path), 1)

        own.write("brand-new.txt", "never staged")
        XCTAssertEqual(
            probe.uncommittedFileCount(inWorktree: own.path), 2,
            "an agent that wrote a file and never staged it left work behind too"
        )
    }

    func testAncestryReadsAgainstACommitAsWellAsABranch() throws {
        let head = try XCTUnwrap(revision("main"))
        let before = try XCTUnwrap(revision("main~3"), "the commit the fixture branched everything from")

        XCTAssertTrue(
            (probe.branches(inRepository: repository.path, mergedInto: head) ?? []).contains("fast-forward"),
            "the built commit is named by its sha, which is all a bundle can record"
        )
        XCTAssertFalse(
            (probe.branches(inRepository: repository.path, mergedInto: before) ?? []).contains("fast-forward"),
            "and an earlier commit must answer differently, or nothing is being asked"
        )
    }

    func testAWorktreeAndItsRepositoryShareACommonDirectory() throws {
        let own = try TestRepository()
        defer { own.discard() }

        let worktree = own.url.appendingPathComponent("linked")
        own.git("worktree", "add", "-q", worktree.path, "-b", "linked", "main")

        XCTAssertEqual(
            probe.commonDirectory(inRepository: worktree.path),
            probe.commonDirectory(inRepository: own.path),
            "a session in a worktree is working on the same repository the app was built from"
        )
        XCTAssertNotEqual(
            probe.commonDirectory(inRepository: own.path),
            probe.commonDirectory(inRepository: repository.path),
            "and a different checkout must not read as the same one"
        )
    }

    func testABranchIsToldApartFromTheCommitItWasCutFrom() throws {
        let own = try TestRepository()
        defer { own.discard() }

        own.git("branch", "untouched", "main")
        own.branch("worked")
        own.commit("worked.txt", "w", as: "work")

        XCTAssertEqual(
            probe.branchMoved(sinceCreationOf: "untouched", inRepository: own.path), false,
            "an agent that opened a worktree and committed nothing left no work behind"
        )
        XCTAssertEqual(probe.branchMoved(sinceCreationOf: "worked", inRepository: own.path), true)
        XCTAssertNil(probe.branchMoved(sinceCreationOf: "never-existed", inRepository: own.path))
    }

    func testMissingDirectoryIsNilNotACrash() {
        XCTAssertNil(probe.branches(inRepository: "/nowhere/at/all"))
        XCTAssertNil(probe.uncommittedFileCount(inWorktree: "/nowhere/at/all"))
        XCTAssertNil(probe.commonDirectory(inRepository: "/nowhere/at/all"))
    }

    private func revision(_ name: String) -> String? {
        guard let result = try? Shell.run(["git", "-C", repository.path, "rev-parse", name]),
              result.exitCode == 0
        else { return nil }
        return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func testNonRepositoryIsNil() {
        XCTAssertNil(probe.branches(inRepository: NSTemporaryDirectory()))
    }

    private static var gitIsAvailable: Bool {
        (try? Shell.run(["git", "--version"]))?.exitCode == 0
    }
}

final class MergeStatusWordingTests: XCTestCase {

    func testMergedNamesTheBaseBranch() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 0).label,
            "in main",
            "never a bare 'merged' — the base is inferred, so it must be visible"
        )
        XCTAssertEqual(
            WorktreeMergeStatus(base: "develop", merge: .merged, uncommittedFiles: nil).label,
            "in develop"
        )
    }

    func testMergedButDirtyLeadsWithTheRemainingWork() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 8).label,
            "8 uncommitted"
        )
        XCTAssertTrue(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 8)
                .help.contains("in main"),
            "the claim isn't dropped, it moves to the hover"
        )
    }

    func testOutstandingLabelPluralisesTheCommitCount() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 1)).label,
            "1 commit not in main"
        )
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 2)).label,
            "2 commits not in main"
        )
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 2), uncommittedFiles: 3).label,
            "2 commits not in main · 3 uncommitted"
        )
    }

    func testBranchGoneReportsNeitherState() {
        let status = WorktreeMergeStatus(base: "main", merge: .branchGone)
        XCTAssertEqual(status.label, "branch gone")
        XCTAssertTrue(status.help.contains("discarded"))
        XCTAssertFalse(status.help.hasPrefix("merged"))
    }

    func testOutstandingHelpTextMentionsTheSquashLimitation() {
        XCTAssertTrue(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 2))
                .help.lowercased().contains("squash")
        )
    }

    func testWorkTheBuildIsBehindSaysSoInsteadOfSayingItLanded() {
        let status = WorktreeMergeStatus(
            base: "main", merge: .merged, uncommittedFiles: 0, build: .awaitingRestart
        )
        XCTAssertEqual(status.label, "not in this build")
        XCTAssertTrue(status.help.contains("in main"), "it did land — the hover still says so")
        XCTAssertTrue(status.help.lowercased().contains("restart"))
    }

    func testRunningWorkReadsExactlyAsItDidBeforeTheBuildWasKnown() {
        for dirty in [nil, 0, 3] {
            let known = WorktreeMergeStatus(
                base: "main", merge: .merged, uncommittedFiles: dirty, build: .inBuild
            )
            let unknown = WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: dirty)
            XCTAssertEqual(known.label, unknown.label)
            XCTAssertEqual(known.help, unknown.help)
            XCTAssertEqual(known.tone, unknown.tone)
        }
    }

    func testUncommittedWorkIsStillNamedWhenTheBuildIsBehind() {
        XCTAssertEqual(
            WorktreeMergeStatus(
                base: "main", merge: .merged, uncommittedFiles: 3, build: .awaitingRestart
            ).label,
            "not in this build · 3 uncommitted"
        )
    }

    func testTheFleetIsToldOnlyWhetherItLanded() {
        XCTAssertEqual(
            WorktreeMergeStatus(
                base: "main", merge: .merged, uncommittedFiles: 0, build: .awaitingRestart
            ).mergeLabel,
            "in main",
            "another agent has no build of ours to be behind — 'this build' means nothing to it"
        )
    }
}

final class MergeBadgeVisibilityTests: XCTestCase {

    func testLandedAndCleanDrawsNothing() {
        XCTAssertFalse(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 0).needsAttention
        )
        XCTAssertFalse(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: nil).needsAttention,
            "a reaped worktree is the ordinary end of a landed session, not a badge"
        )
    }

    func testBranchGoneDrawsNothing() {
        XCTAssertFalse(WorktreeMergeStatus(base: "main", merge: .branchGone).needsAttention)
    }

    func testOutstandingWorkIsDrawn() {
        XCTAssertTrue(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 2)).needsAttention
        )
        XCTAssertTrue(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 8).needsAttention,
            "landed but dirty still wants something — deleting that worktree loses work"
        )
    }

    func testWorkTheBuildIsBehindIsDrawn() {
        XCTAssertTrue(
            WorktreeMergeStatus(
                base: "main", merge: .merged, uncommittedFiles: 0, build: .awaitingRestart
            ).isNotable,
            "the only window in which this is worth saying is between landing and restarting"
        )
        XCTAssertFalse(
            WorktreeMergeStatus(
                base: "main", merge: .merged, uncommittedFiles: 0, build: .inBuild
            ).isNotable,
            "and it must clear itself once the restart happens"
        )
    }

    func testEveryDrawnStatusUsesTheSameTone() {
        for status in Self.everyShape where status.needsAttention {
            XCTAssertEqual(status.tone, .attention, "\(status.label) used a different tone")
        }
    }

    func testWorkTheBuildIsBehindIsNotDrawnAsSomethingToFix() {
        for status in Self.everyShape where status.awaitsRestart && !status.needsAttention {
            XCTAssertEqual(
                status.tone, .awaitingRestart,
                "\(status.label): nothing is wrong with it, it just isn't running"
            )
        }
    }

    func testNoDrawnStatusReportsWorkAsLanded() {
        for status in Self.everyShape where status.isNotable {
            XCTAssertFalse(
                status.label.contains("in main") && !status.label.contains("not in"),
                "\(status.label) still tells you it landed"
            )
        }
    }

    private static let everyShape: [WorktreeMergeStatus] = {
        let merges: [BranchMergeState] = [
            .merged, .outstanding(commits: 1), .outstanding(commits: 3), .branchGone,
        ]
        return merges.flatMap { merge in
            [nil, BuildInclusion.inBuild, .awaitingRestart].flatMap { build in
                [nil, 0, 1, 8].map {
                    WorktreeMergeStatus(
                        base: "main", merge: merge, uncommittedFiles: $0, build: build
                    )
                }
            }
        }
    }()
}

final class MergeToneTests: XCTestCase {

    func testLandedHasItsOwnTone() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 0).tone,
            .landed
        )
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: nil).tone,
            .landed,
            "a reaped worktree has nothing left in it either"
        )
    }

    func testOutstandingCommitsUseTheNeedsYouTone() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 2)).tone,
            .attention
        )
    }

    func testMergedButDirtyIsNotLanded() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 8).tone,
            .attention
        )
    }

    func testBranchGoneHasNoTone() {
        XCTAssertEqual(
            WorktreeMergeStatus(base: "main", merge: .branchGone).tone,
            .indeterminate
        )
    }

    func testToneAndNeedsAttentionAgree() {
        let cases = [
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 0),
            WorktreeMergeStatus(base: "main", merge: .merged, uncommittedFiles: 4),
            WorktreeMergeStatus(base: "main", merge: .outstanding(commits: 1)),
            WorktreeMergeStatus(base: "main", merge: .branchGone),
        ]
        for status in cases {
            XCTAssertEqual(
                status.tone == .attention, status.needsAttention,
                "\(status.label) disagrees with itself"
            )
        }
    }
}
