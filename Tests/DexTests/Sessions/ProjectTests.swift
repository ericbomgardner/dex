import XCTest
@testable import DexCore

final class ProjectTests: XCTestCase {
    private func row(_ name: String, cwd: String, state: HostSessionState = .done, pid: Int? = nil)
        -> SessionRowModel
    {
        makeRow(name, state: state, hostPID: pid, cwd: cwd)
    }

    func testSessionsGroupByWorkingDirectory() {
        let summaries = ProjectIndex.summaries(for: [
            row("a", cwd: "/Users/e/Projects/alpha"),
            row("b", cwd: "/Users/e/Projects/alpha"),
            row("c", cwd: "/Users/e/Projects/beta"),
        ])
        XCTAssertEqual(summaries.map(\.name), ["alpha", "beta"])
        XCTAssertEqual(summaries.map(\.total), [2, 1])
    }

    func testSummaryCountsBlockedAndLiveSeparately() {
        let summaries = ProjectIndex.summaries(for: [
            row("waiting", cwd: "/p/alpha", state: .asking),
            row("running", cwd: "/p/alpha", state: .running, pid: 42),
            row("over", cwd: "/p/alpha", state: .done),
        ])
        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].total, 3)
        XCTAssertEqual(summaries[0].blocked, 1)
        XCTAssertEqual(summaries[0].live, 1)
    }

    func testResolvingAWaitingRowDropsItFromThePickerCount() {
        let waiting = row("waiting", cwd: "/p/alpha", state: .asking)
        var marks = SessionResolutions()
        marks.resolve(waiting, at: now)

        let summaries = ProjectIndex.summaries(for: [waiting], resolutions: marks)
        XCTAssertEqual(summaries[0].blocked, 0)
    }

    func testProjectsSortByDisplayName() {
        let summaries = ProjectIndex.summaries(for: [
            row("c", cwd: "/p/zulu"),
            row("a", cwd: "/p/alpha"),
            row("b", cwd: "/p/mike"),
        ])
        XCTAssertEqual(summaries.map(\.name), ["alpha", "mike", "zulu"])
    }

    func testNoRowsMeansNoProjects() {
        XCTAssertTrue(ProjectIndex.summaries(for: []).isEmpty)
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func aged(
        _ name: String,
        cwd: String,
        state: HostSessionState = .done,
        hoursAgo: Double,
        pid: Int? = nil
    ) -> SessionRowModel {
        let at = now.addingTimeInterval(-hoursAgo * 3600).timeIntervalSince1970 * 1000
        return makeRow(
            name, state: state, startedAt: at, hostPID: pid, cwd: cwd,
            pinnedUpdate: Date(timeIntervalSince1970: at / 1000)
        )
    }

    private func summaries(
        for rows: [SessionRowModel],
        resolutions: SessionResolutions = SessionResolutions()
    ) -> [ProjectSummary] {
        ProjectIndex.summaries(for: rows) {
            SessionSections.counts($0, resolutions: resolutions)
        }
    }

    func testThePickerCountMatchesTheSelectedProjectRowCount() {
        let rows = [
            aged("waiting", cwd: "/p/alpha", state: .asking, hoursAgo: 40),
            aged("running", cwd: "/p/alpha", state: .running, hoursAgo: 40, pid: 7),
            aged("fresh", cwd: "/p/alpha", hoursAgo: 2),
            aged("stale", cwd: "/p/alpha", hoursAgo: 40),
            aged("dealt-with", cwd: "/p/alpha", hoursAgo: 2),
            aged("elsewhere", cwd: "/p/beta", hoursAgo: 2),
        ]
        var marks = SessionResolutions()
        marks.resolve(rows[4], at: now)

        let picker = summaries(for: rows, resolutions: marks)
        XCTAssertEqual(picker.map(\.name), ["alpha", "beta"])

        for summary in picker {
            let visible = SessionFilter(project: summary.path).apply(to: rows).visible
            XCTAssertEqual(
                summary.active,
                marks.split(visible).active.count,
                "the picker's number must be the row count you get on picking \(summary.name)"
            )
        }

        XCTAssertEqual(picker.map(\.active), [4, 1])
    }

    func testAgeDoesNotTakeARowOutOfTheCount() {
        let rows = [
            aged("fresh", cwd: "/p/alpha", hoursAgo: 2),
            aged("stale", cwd: "/p/alpha", hoursAgo: 40),
        ]
        XCTAssertEqual(summaries(for: rows).map(\.active), [2])
    }

    func testAProjectWithNoVisibleRowsIsStillListed() {
        let rows = [aged("done-with", cwd: "/p/alpha", hoursAgo: 2)]
        var marks = SessionResolutions()
        marks.resolve(rows[0], at: now)

        let picker = summaries(for: rows, resolutions: marks)
        XCTAssertEqual(picker.map(\.name), ["alpha"])
        XCTAssertEqual(picker[0].active, 0)
        XCTAssertEqual(picker[0].total, 1, "the probe counts every row, not just the visible ones")
    }

    func testCountingEverythingIsTheDefault() {
        let rows = [
            aged("fresh", cwd: "/p/alpha", hoursAgo: 2),
            aged("stale", cwd: "/p/alpha", hoursAgo: 40),
        ]
        let summary = ProjectIndex.summaries(for: rows)[0]
        XCTAssertEqual(summary.active, summary.total)
    }

    func testUniqueLeavesRenderAsTheLeaf() {
        let names = ProjectIndex.displayNames(for: [
            "/Users/e/Projects/garden-planner",
            "/Users/e/Projects/orchard/memory",
        ])
        XCTAssertEqual(names["/Users/e/Projects/garden-planner"], "garden-planner")
        XCTAssertEqual(names["/Users/e/Projects/orchard/memory"], "memory")
    }

    func testCollidingLeavesGrowLeftwardsUntilDistinct() {
        let names = ProjectIndex.displayNames(for: [
            "/Users/e/Projects/orchard/memory",
            "/Users/e/Projects/atlas/memory",
        ])
        XCTAssertEqual(names["/Users/e/Projects/orchard/memory"], "orchard/memory")
        XCTAssertEqual(names["/Users/e/Projects/atlas/memory"], "atlas/memory")
    }

    func testNonCollidingNamesAreNotLengthened() {
        let names = ProjectIndex.displayNames(for: [
            "/Users/e/Projects/orchard/memory",
            "/Users/e/Projects/atlas/memory",
            "/Users/e/Projects/garden-planner",
        ])
        XCTAssertEqual(names["/Users/e/Projects/garden-planner"], "garden-planner")
        XCTAssertEqual(names["/Users/e/Projects/orchard/memory"], "orchard/memory")
    }

    func testDeeperCollisionsKeepGrowing() {
        let names = ProjectIndex.displayNames(for: [
            "/a/one/shared/memory",
            "/b/two/shared/memory",
        ])
        XCTAssertEqual(names["/a/one/shared/memory"], "one/shared/memory")
        XCTAssertEqual(names["/b/two/shared/memory"], "two/shared/memory")
        XCTAssertNotEqual(names["/a/one/shared/memory"], names["/b/two/shared/memory"])
    }

    func testSuffixPathsStayDistinct() {
        let names = ProjectIndex.displayNames(for: ["/memory", "/a/b/memory"])
        XCTAssertEqual(Set(names.values).count, 2)
    }

    func testDuplicatePathsCollapseToOneEntry() {
        let names = ProjectIndex.displayNames(for: ["/p/alpha", "/p/alpha"])
        XCTAssertEqual(names.count, 1)
        XCTAssertEqual(names["/p/alpha"], "alpha")
    }

    func testRootPathDoesNotCrash() {
        let names = ProjectIndex.displayNames(for: ["/"])
        XCTAssertEqual(names["/"], "/")
    }

    private func worktreeRow(_ name: String, origin: String, branch: String) -> SessionRowModel {
        makeRow(
            name,
            state: .running,
            hostPID: 4242,
            cwd: "\(origin)/.claude/worktrees/\(branch)",
            worktree: WorktreeOrigin(path: origin, branch: "worktree-\(branch)")
        )
    }

    func testALiveWorktreeSessionGroupsUnderItsOriginRepoNotItsBranch() {
        let origin = "/Users/e/Projects/agents"
        let summaries = ProjectIndex.summaries(for: [
            row("plain", cwd: origin, state: .running),
            worktreeRow("isolated", origin: origin, branch: "hide-deleted-projects"),
        ])
        XCTAssertEqual(summaries.count, 1, "the worktree must not become its own project")
        XCTAssertEqual(summaries[0].path, origin)
        XCTAssertEqual(summaries[0].total, 2)
    }

    func testProjectPathPrefersTheWorktreeOrigin() {
        let worktree = worktreeRow("isolated", origin: "/repo", branch: "feature")
        XCTAssertEqual(worktree.projectPath, "/repo")
        XCTAssertEqual(worktree.session.cwd, "/repo/.claude/worktrees/feature")
        XCTAssertNotNil(worktree.worktree)
        XCTAssertEqual(worktree.worktreeBranch, "worktree-feature")
    }

    func testAnOrdinarySessionIsNotReportedAsAWorktree() {
        let plain = makeRow("plain", state: .running, cwd: "/repo")
        XCTAssertEqual(plain.projectPath, "/repo")
        XCTAssertNil(plain.worktree)
        XCTAssertNil(plain.worktreeBranch)
    }

    func testFallsBackToTheSessionDirectoryWithoutAJoin() {
        let orphan = makeRow("unjoined", state: .running, cwd: "/repo/.claude/worktrees/x")
        XCTAssertEqual(orphan.projectPath, "/repo/.claude/worktrees/x")
        XCTAssertNil(orphan.worktree)
    }
}
