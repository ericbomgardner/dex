import XCTest
@testable import DexCore

final class CLIVersionTests: XCTestCase {

    func testReadsAVersionOutOfWhatTheCLIPrints() {
        XCTAssertEqual(CLIVersion("2.1.234 (Claude Code)")?.description, "2.1.234")
    }

    /// Compared as numbers, not as text — the reason this is a type at all.
    func testOrdersByNumberRatherThanByText() throws {
        let nine = try XCTUnwrap(CLIVersion("2.1.9"))
        let ten = try XCTUnwrap(CLIVersion("2.1.10"))
        XCTAssertTrue(nine < ten)
        XCTAssertFalse(ten < nine)
    }

    func testEqualVersionsAreNeitherAheadNorBehind() throws {
        let a = try XCTUnwrap(CLIVersion("2.1.234"))
        XCTAssertFalse(a < a)
    }

    func testTextWithNoVersionIsNotOne() {
        XCTAssertNil(CLIVersion("claude: command not found"))
        XCTAssertNil(CLIVersion("2.1"))
    }
}
