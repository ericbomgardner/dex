import XCTest
@testable import DexCore

final class QuickSwitchIndexTests: XCTestCase {

    private func row(
        _ name: String,
        cwd: String,
        state: HostSessionState = .done,
        startedAt: Double = 1_000_000
    ) -> SessionRowModel {
        makeRow(name, state: state, startedAt: startedAt, cwd: cwd)
    }

    private func results(
        query: String = "",
        scope: QuickSwitchScope = .everything,
        rows: [SessionRowModel],
        isFiltered: Bool = false
    ) -> QuickSwitchResults {
        QuickSwitchIndex.results(
            query: query,
            scope: scope,
            projects: ProjectIndex.summaries(for: rows),
            sessions: rows,
            isFiltered: isFiltered
        )
    }

    private func names(_ results: [QuickSwitchResult]) -> [String] {
        results.map(\.name)
    }

    func testAnEmptyQueryListsEveryProjectAndSession() {
        let found = results(rows: [
            row("alpha-run", cwd: "/p/alpha"),
            row("beta-run", cwd: "/p/beta"),
        ])

        XCTAssertEqual(names(found.projects), ["alpha", "beta"])
        XCTAssertEqual(names(found.sessions), ["alpha-run", "beta-run"])
    }

    func testProjectsWaitingOnYouComeFirst() {
        let found = results(rows: [
            row("recent", cwd: "/p/quiet", startedAt: 9_000_000),
            row("asking", cwd: "/p/blocked", state: .asking, startedAt: 1_000),
        ])

        XCTAssertEqual(names(found.projects), ["blocked", "quiet"])
    }

    func testProjectsWithoutAnyoneWaitingFallBackToRecency() {
        let found = results(rows: [
            row("old", cwd: "/p/stale", startedAt: 1_000),
            row("new", cwd: "/p/fresh", startedAt: 9_000_000),
        ])

        XCTAssertEqual(names(found.projects), ["fresh", "stale"])
    }

    func testSessionsKeepTheOrderTheyArriveIn() {
        let rows = [
            row("second", cwd: "/p/alpha"),
            row("first", cwd: "/p/alpha"),
        ]

        XCTAssertEqual(names(results(rows: rows).sessions), ["second", "first"])
    }

    func testInitialsBeatTheSameLettersBuriedMidWord() {
        let found = results(query: "caw", rows: [
            row("a", cwd: "/p/cinema-flower"),
            row("b", cwd: "/p/copper-agents-worker"),
        ])

        XCTAssertEqual(names(found.projects), ["copper-agents-worker", "cinema-flower"])
    }

    /// The rule fzf and Cmd-P follow: letters typed in a row outrank the same
    /// letters spread over word starts.
    func testAContiguousMatchOutranksScatteredWordStarts() {
        let found = results(query: "caw", rows: [
            row("a", cwd: "/p/cadence-web"),
            row("b", cwd: "/p/copper-agents-worker"),
        ])

        XCTAssertEqual(names(found.projects), ["cadence-web", "copper-agents-worker"])
    }

    func testNonMatchesAreDroppedOnceYouType() {
        let found = results(query: "alpha", rows: [
            row("alpha-run", cwd: "/p/alpha"),
            row("beta-run", cwd: "/p/beta"),
        ])

        XCTAssertEqual(names(found.projects), ["alpha"])
        XCTAssertEqual(names(found.sessions), ["alpha-run"])
    }

    /// Paths are deliberately unsearchable, or every project under a parent
    /// directory answers to that directory's name.
    func testTheFolderPathIsNotSearched() {
        let found = results(query: "projects", rows: [
            row("run", cwd: "/Users/test/Projects/alpha"),
        ])

        XCTAssertTrue(found.isEmpty)
    }

    func testClearingTheFilterIsOfferedOnlyWhileFiltered() {
        let rows = [row("run", cwd: "/p/alpha")]

        XCTAssertEqual(names(results(rows: rows, isFiltered: true).projects).last,
                       QuickSwitchIndex.allProjectsName)
        XCTAssertFalse(names(results(rows: rows).projects).contains(QuickSwitchIndex.allProjectsName))
    }

    func testClearingTheFilterIsSearchableToo() {
        let rows = [row("run", cwd: "/p/alpha")]

        XCTAssertEqual(names(results(query: "allp", rows: rows, isFiltered: true).projects),
                       [QuickSwitchIndex.allProjectsName])
        XCTAssertTrue(results(query: "zz", rows: rows, isFiltered: true).isEmpty)
    }

    func testTheProjectsOnlyScopeLeavesSessionsOut() {
        let found = results(scope: .projectsOnly, rows: [row("alpha-run", cwd: "/p/alpha")])

        XCTAssertEqual(names(found.projects), ["alpha"])
        XCTAssertTrue(found.sessions.isEmpty)
    }

    func testOrderedWalksProjectsBeforeSessions() {
        let found = results(rows: [row("alpha-run", cwd: "/p/alpha")])

        XCTAssertEqual(names(found.ordered), ["alpha", "alpha-run"])
    }
}
