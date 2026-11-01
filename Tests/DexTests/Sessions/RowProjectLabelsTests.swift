import XCTest
@testable import DexCore

final class RowProjectLabelsTests: XCTestCase {

    func testAnUnfilteredListNamesEachRowsProject() {
        let rows = [
            makeRow("a", state: .done, cwd: "/Users/e/Projects/memory"),
            makeRow("b", state: .done, cwd: "/Users/e/Projects/wrapper"),
        ]
        let labels = RowProjectLabels(rows: rows, selectedProject: nil)

        XCTAssertEqual(labels.label(for: rows[0]), "memory")
        XCTAssertEqual(labels.label(for: rows[1]), "wrapper")
    }

    func testSelectingAProjectHidesTheLabelOnEveryRow() {
        let rows = [
            makeRow("a", state: .done, cwd: "/Users/e/Projects/memory"),
            makeRow("b", state: .done, cwd: "/Users/e/Projects/memory"),
        ]
        let labels = RowProjectLabels(rows: rows, selectedProject: "/Users/e/Projects/memory")

        for row in rows {
            XCTAssertNil(labels.label(for: row))
        }
    }

    func testTwoProjectsSharingALeafGetDistinctNames() {
        let rows = [
            makeRow("a", state: .done, cwd: "/Users/e/orchard/memory"),
            makeRow("b", state: .done, cwd: "/Users/e/tools/memory"),
        ]
        let labels = RowProjectLabels(rows: rows, selectedProject: nil)

        XCTAssertEqual(labels.label(for: rows[0]), "orchard/memory")
        XCTAssertEqual(labels.label(for: rows[1]), "tools/memory")
        XCTAssertEqual(
            Set([labels.label(for: rows[0]), labels.label(for: rows[1])]).count, 2,
            "two projects rendered under one name"
        )
    }

    func testTheRowsNameIsThePickersName() {
        let rows = [
            makeRow("a", state: .done, cwd: "/Users/e/orchard/memory"),
            makeRow("b", state: .done, cwd: "/Users/e/tools/memory"),
            makeRow("c", state: .done, cwd: "/Users/e/Projects/wrapper"),
        ]
        let labels = RowProjectLabels(rows: rows, selectedProject: nil)
        let picker = ProjectIndex.summaries(for: rows)

        for row in rows {
            let fromPicker = picker.first { $0.path == row.projectPath }?.name
            XCTAssertEqual(labels.label(for: row), fromPicker, row.projectPath)
        }
    }

    func testAWorktreeSessionIsLabelledWithItsRepository() {
        let live = makeRow(
            "isolated", state: .running, hostPID: 900,
            cwd: "/Users/e/Projects/wrapper/.claude/worktrees/feature",
            worktree: WorktreeOrigin(path: "/Users/e/Projects/wrapper",
                                     branch: "worktree-feature")
        )
        let plain = makeRow("plain", state: .done, cwd: "/Users/e/Projects/wrapper")
        let labels = RowProjectLabels(rows: [live, plain], selectedProject: nil)

        XCTAssertEqual(labels.label(for: live), "wrapper")
        XCTAssertEqual(labels.label(for: live), labels.label(for: plain),
                       "a worktree session and its sibling are in the same project")

        XCTAssertEqual(live.worktreeBranch, "worktree-feature")
    }

    func testTheTooltipNamesTheDirectoryTheLabelAbbreviates() {
        let row = makeRow("a", state: .done, cwd: "/Users/e/Projects/memory")
        let labels = RowProjectLabels(rows: [row], selectedProject: nil)

        XCTAssertEqual(labels.path(for: row), Format.tildePath("/Users/e/Projects/memory"))
        XCTAssertTrue(labels.path(for: row).hasSuffix("Projects/memory"))
    }
}
