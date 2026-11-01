import XCTest
@testable import DexCore

private let repository = "/repo"
private let worktree = "/repo/.claude/worktrees/feature"

private func makeWorktreeRow(
    _ name: String,
    state: HostSessionState = .done,
    branch: String = "worktree-feature",
    path: String = worktree,
    pid: Int? = nil
) -> SessionRowModel {
    makeRow(
        name,
        state: state,
        hostPID: pid,
        cwd: path,
        worktree: WorktreeOrigin(path: repository, branch: branch)
    )
}

private func landedGit(dirty: Int = 0) -> ScriptedGit {
    let git = ScriptedGit()
    git.branchesByRepository[repository] = ["main", "worktree-feature"]
    git.mergedByBase["\(repository)|main"] = ["main", "worktree-feature"]
    git.headByRepository[repository] = "main"
    git.dirtyByWorktree[worktree] = dirty
    return git
}

final class WorktreeNomineeTests: XCTestCase {

    func testNominatesAFinishedWorktreeRow() {
        let row = makeWorktreeRow("a")
        let tree = WorktreeRetirement.nominee(row, among: [row])

        XCTAssertEqual(tree?.path, worktree)
        XCTAssertEqual(tree?.branch, "worktree-feature")
        XCTAssertEqual(tree?.repository, repository, "the tree comes back off the origin, not the cwd")
    }

    func testIgnoresARowWithNoWorktree() {
        let row = makeRow("a", state: .done, cwd: repository)
        XCTAssertNil(WorktreeRetirement.nominee(row, among: [row]))
    }

    func testRefusesARowThatIsStillWorking() {
        for state: HostSessionState in [.running, .asking, .unknown("busy")] {
            let row = makeWorktreeRow("a", state: state)
            XCTAssertNil(
                WorktreeRetirement.nominee(row, among: [row]),
                "\(state.raw) can be resolved but is a session you mean to come back to"
            )
        }
    }

    func testRefusesARowWithALiveProcess() {
        let row = makeWorktreeRow("a", pid: 4321)
        XCTAssertNil(WorktreeRetirement.nominee(row, among: [row]))
    }

    func testRefusesAWorktreeAnotherRowIsStillWorkingIn() {
        let finished = makeWorktreeRow("a")
        let busy = makeWorktreeRow("b", state: .running)

        XCTAssertNil(
            WorktreeRetirement.nominee(finished, among: [finished, busy]),
            "a session resumed under a new key is a second row on the same path"
        )
    }

    func testAllowsAWorktreeWhoseOtherRowsHaveAlsoFinished() {
        let finished = makeWorktreeRow("a")
        let alsoFinished = makeWorktreeRow("b", state: .idle)

        XCTAssertNotNil(WorktreeRetirement.nominee(finished, among: [finished, alsoFinished]))
    }

    func testIgnoresBusyRowsInOtherWorktrees() {
        let finished = makeWorktreeRow("a")
        let elsewhere = makeWorktreeRow("b", state: .running, path: "/repo/.claude/worktrees/other")

        XCTAssertNotNil(WorktreeRetirement.nominee(finished, among: [finished, elsewhere]))
    }

    func testRefusesTheCheckoutTheRunningAppWasBuiltFrom() {
        let row = makeWorktreeRow("a")
        let build = RunningBuild(commit: "abc1234", checkoutRoot: worktree)

        XCTAssertNil(
            WorktreeRetirement.nominee(row, among: [row], runningBuild: build),
            "removing it would take the rebuild's own checkout with it"
        )
    }

    func testAllowsAWorktreeThatIsNotTheRunningBuild() {
        let row = makeWorktreeRow("a")
        let build = RunningBuild(commit: "abc1234", checkoutRoot: repository)

        XCTAssertNotNil(WorktreeRetirement.nominee(row, among: [row], runningBuild: build))
    }
}

final class WorktreeFinishedTests: XCTestCase {

    private let tree = RetiredWorktree(
        path: worktree, branch: "worktree-feature", repository: repository
    )

    func testMergedAndCleanIsFinished() {
        XCTAssertTrue(WorktreeRetirement.isFinished(tree, probe: landedGit()))
    }

    func testUncommittedFilesAreNotFinished() {
        XCTAssertFalse(WorktreeRetirement.isFinished(tree, probe: landedGit(dirty: 1)))
    }

    func testAnUnreadableWorktreeIsNotFinished() {
        let git = landedGit()
        git.dirtyByWorktree = [:]
        XCTAssertFalse(
            WorktreeRetirement.isFinished(tree, probe: git),
            "git declining to answer must not read as a clean tree"
        )
    }

    func testOutstandingCommitsAreNotFinished() {
        let git = landedGit()
        git.mergedByBase["\(repository)|main"] = ["main"]
        git.outstandingByBranch["worktree-feature"] = 2

        XCTAssertFalse(WorktreeRetirement.isFinished(tree, probe: git))
    }

    func testAncestryIsNotTheOnlyWayToLand() {
        let git = landedGit()
        git.mergedByBase["\(repository)|main"] = ["main"]
        git.outstandingByBranch["worktree-feature"] = 0

        XCTAssertTrue(
            WorktreeRetirement.isFinished(tree, probe: git),
            "a rebased branch is no ancestor of main, but every patch of it is in"
        )
    }

    func testAMissingBranchIsNotFinished() {
        let git = landedGit()
        git.branchesByRepository[repository] = ["main"]

        XCTAssertFalse(
            WorktreeRetirement.isFinished(tree, probe: git),
            "merged-and-cleaned-up and discarded look identical from here"
        )
    }

    func testTheBaseBranchesOwnCheckoutIsNotFinished() {
        let git = landedGit()
        let base = RetiredWorktree(path: worktree, branch: "main", repository: repository)

        XCTAssertFalse(WorktreeRetirement.isFinished(base, probe: git))
    }

    func testARepositoryWithNoBaseBranchIsNotFinished() {
        let git = landedGit()
        git.branchesByRepository[repository] = ["worktree-feature"]
        git.headByRepository[repository] = "worktree-feature"

        XCTAssertFalse(WorktreeRetirement.isFinished(tree, probe: git))
    }
}

final class WorktreeStillNominatedTests: XCTestCase {

    private let tree = RetiredWorktree(
        path: worktree, branch: "worktree-feature", repository: repository
    )

    private func settled(_ row: SessionRowModel) -> SessionResolutions {
        var marks = SessionResolutions()
        marks.resolve(row)
        return marks
    }

    func testStandsWhileTheRowIsStillSettled() {
        let row = makeWorktreeRow("a")
        XCTAssertTrue(WorktreeRetirement.stillNominated(
            tree, rowID: row.rowID, among: [row], resolutions: settled(row)
        ))
    }

    func testFallsWhenTheRowIsUnresolved() {
        let row = makeWorktreeRow("a")
        XCTAssertFalse(
            WorktreeRetirement.stillNominated(
                tree, rowID: row.rowID, among: [row], resolutions: SessionResolutions()
            ),
            "the same click that resolved the row puts it back"
        )
    }

    func testFallsWhenTheRowSaysSomethingAfterTheMark() {
        let row = makeWorktreeRow("a")
        let marks = settled(row)
        let spoke = makeWorktreeRow("a")
            .refreshed(activityAt: nil, pinnedUpdate: Date().addingTimeInterval(60))

        XCTAssertFalse(
            WorktreeRetirement.stillNominated(
                tree, rowID: spoke.rowID, among: [spoke], resolutions: marks
            ),
            "a settled row that has moved since the mark is not settled any more"
        )
    }

    func testFallsWhenTheSessionIsWorkingAgain() {
        let row = makeWorktreeRow("a")
        let marks = settled(row)
        let resumed = makeWorktreeRow("a", state: .running)

        XCTAssertFalse(
            WorktreeRetirement.stillNominated(
                tree, rowID: resumed.rowID, among: [resumed], resolutions: marks
            ),
            "git can still read the tree clean before a resumed turn writes anything"
        )
    }

    func testStandsWhenTheRowHasLeftTheListEntirely() {
        let row = makeWorktreeRow("a")
        XCTAssertTrue(
            WorktreeRetirement.stillNominated(
                tree, rowID: row.rowID, among: [], resolutions: settled(row)
            ),
            "nothing is left to be working in the tree"
        )
    }

    func testFallsWhenTheRunningBuildMovedIntoTheTree() {
        let row = makeWorktreeRow("a")
        XCTAssertFalse(WorktreeRetirement.stillNominated(
            tree,
            rowID: row.rowID,
            among: [row],
            resolutions: settled(row),
            runningBuild: RunningBuild(commit: "abc1234", checkoutRoot: worktree)
        ))
    }
}

final class WorktreeRetireTests: XCTestCase {

    private let tree = RetiredWorktree(
        path: worktree, branch: "worktree-feature", repository: repository
    )

    func testRemovesTheCheckoutAndLeavesTheBranch() {
        let git = landedGit()

        XCTAssertTrue(WorktreeRetirement.retire(tree, probe: git))
        XCTAssertEqual(git.removedWorktrees, [worktree])
        XCTAssertEqual(
            git.branchesByRepository[repository], ["main", "worktree-feature"],
            "resolving is reversible, so the branch it could come back from stays"
        )
    }

    func testRemovesNothingWhenTheTreeIsNotFinished() {
        let git = landedGit(dirty: 3)

        XCTAssertFalse(WorktreeRetirement.retire(tree, probe: git))
        XCTAssertEqual(git.removedWorktrees, [])
    }

    func testReportsAGitRefusal() {
        let git = landedGit()
        git.removalSucceeds = false

        XCTAssertFalse(
            WorktreeRetirement.retire(tree, probe: git),
            "git's own reading of the tree gets the last word"
        )
    }
}
