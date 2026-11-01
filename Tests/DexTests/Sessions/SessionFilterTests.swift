import XCTest
@testable import DexCore

final class SessionFilterTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func row(
        _ name: String,
        state: HostSessionState,
        hoursAgo: Double,
        updatedHoursAgo: Double? = nil,
        pid: Int? = nil,
        cwd: String? = nil
    ) -> SessionRowModel {
        let started = now.addingTimeInterval(-hoursAgo * 3600).timeIntervalSince1970 * 1000
        let updated = now.addingTimeInterval(-(updatedHoursAgo ?? hoursAgo) * 3600)
        return makeRow(
            name, state: state, startedAt: started, hostPID: pid,
            cwd: cwd, pinnedUpdate: updated
        )
    }

    private func apply(
        _ rows: [SessionRowModel],
        project: String? = nil,
        resolutions: SessionResolutions = SessionResolutions()
    ) -> SessionFilter.Result {
        SessionFilter(project: project, resolutions: resolutions).apply(to: rows)
    }

    func testAgeKeepsNothingOutOfTheList() {
        let result = apply([
            row("ancient-done", state: .done, hoursAgo: 500),
            row("new-done", state: .done, hoursAgo: 3),
        ])
        XCTAssertEqual(result.visible.map(\.session.displayName), ["ancient-done", "new-done"])
    }

    func testFilteringPreservesOrder() {
        let rows = SessionOrdering.sorted([
            row("old", state: .done, hoursAgo: 40),
            row("blocked", state: .asking, hoursAgo: 90),
            row("working", state: .running, hoursAgo: 1),
        ])
        XCTAssertEqual(
            apply(rows).visible.map(\.session.displayName),
            rows.map(\.session.displayName)
        )
    }

    func testBlockedCountMatchesTheList() {
        let rows = [
            row("old-blocked", state: .asking, hoursAgo: 90),
            row("old-done", state: .done, hoursAgo: 90),
        ]
        XCTAssertEqual(SessionOrdering.blockedCount(rows), 1)
        XCTAssertEqual(apply(rows).visible.count, 2)
    }

    private var mixed: [SessionRowModel] {
        [
            row("alpha-1", state: .running, hoursAgo: 1, cwd: "/p/alpha"),
            row("alpha-2", state: .done, hoursAgo: 2, cwd: "/p/alpha"),
            row("beta-1", state: .running, hoursAgo: 1, cwd: "/p/beta"),
        ]
    }

    func testProjectFilterKeepsOnlyThatProject() {
        let result = apply(mixed, project: "/p/alpha")
        XCTAssertEqual(result.visible.map(\.session.displayName), ["alpha-1", "alpha-2"])
    }

    func testNoProjectFilterHidesNothingByProject() {
        let result = apply(mixed)
        XCTAssertEqual(result.visible.count, 3)
    }

    func testUnknownProjectShowsNothingAndReportsTheHiddenCount() {
        let result = apply(mixed, project: "/p/never-used")
        XCTAssertTrue(result.visible.isEmpty)
    }

    func testTheProjectIsTheOnlyThingThatHides() {
        let rows = [
            row("alpha-live", state: .running, hoursAgo: 1, cwd: "/p/alpha"),
            row("alpha-old", state: .done, hoursAgo: 40, cwd: "/p/alpha"),
            row("beta-old", state: .done, hoursAgo: 40, cwd: "/p/beta"),
            row("beta-live", state: .running, hoursAgo: 1, cwd: "/p/beta"),
        ]
        let result = apply(rows, project: "/p/alpha")
        XCTAssertEqual(result.visible.map(\.session.displayName), ["alpha-live", "alpha-old"])
    }

    func testBlockedSessionsInOtherProjectsAreStillCounted() {
        let rows = [
            row("here", state: .running, hoursAgo: 1, cwd: "/p/alpha"),
            row("waiting-elsewhere", state: .asking, hoursAgo: 1, cwd: "/p/beta"),
            row("also-waiting", state: .asking, hoursAgo: 200, cwd: "/p/gamma"),
        ]
        let result = apply(rows, project: "/p/alpha")
        XCTAssertEqual(result.blockedElsewhere, 2)
        XCTAssertEqual(SessionOrdering.blockedCount(rows), 2)

        var marks = SessionResolutions()
        marks.resolve(rows[1], at: now)
        XCTAssertEqual(apply(rows, project: "/p/alpha", resolutions: marks).blockedElsewhere, 1)
        XCTAssertEqual(SessionOrdering.blockedCount(rows, resolutions: marks), 1)
    }

    func testFilteringToARepoKeepsItsLiveWorktreeSession() {
        let origin = "/p/alpha"
        let worktree = makeRow(
            "isolated",
            state: .running,
            startedAt: now.timeIntervalSince1970 * 1000,
            hostPID: 99,
            cwd: "\(origin)/.claude/worktrees/feature",
            worktree: WorktreeOrigin(path: origin, branch: "worktree-feature")
        )
        let result = apply([row("plain", state: .running, hoursAgo: 1, cwd: origin), worktree],
                           project: origin)
        XCTAssertEqual(result.visible.count, 2)
    }

    func testProjectFilterPreservesOrder() {
        let rows = SessionOrdering.sorted([
            row("alpha-done", state: .done, hoursAgo: 2, cwd: "/p/alpha"),
            row("alpha-blocked", state: .asking, hoursAgo: 9, cwd: "/p/alpha"),
            row("beta-blocked", state: .asking, hoursAgo: 1, cwd: "/p/beta"),
        ])
        XCTAssertEqual(
            apply(rows, project: "/p/alpha").visible.map(\.session.displayName),
            ["alpha-blocked", "alpha-done"]
        )
    }
}
