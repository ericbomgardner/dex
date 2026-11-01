import XCTest
@testable import DexCore

final class WorktreePathTests: XCTestCase {

    func testTrailingSlashesAndDotsAreTheSameWorktree() {
        XCTAssertEqual(WorktreePath.key("/work/a/"), "/work/a")
        XCTAssertEqual(WorktreePath.key("/work/./a"), "/work/a")
        XCTAssertEqual(WorktreePath.key("/work/b/../a"), "/work/a")
    }

    func testAWorktreeContainsItselfAndWhatIsUnderIt() {
        XCTAssertTrue(WorktreePath.contains("/work/a", "/work/a"))
        XCTAssertTrue(WorktreePath.contains("/work/a", "/work/a/Sources/Deep"))
        XCTAssertFalse(WorktreePath.contains("/work/a", "/work/b"))
    }

    /// On a boundary rather than a prefix, or a worktree answers for the one
    /// whose name merely starts the same way.
    func testANameThatStartsTheSameIsADifferentWorktree() {
        XCTAssertFalse(WorktreePath.contains("/work/landing-gate", "/work/landing-gate-two"))
    }

    // What gets published

    /// The skill reads this file, so the names in it are a contract. Both
    /// handles are written down because it has the session id for certain and
    /// the worktree only once the session has made one.
}
