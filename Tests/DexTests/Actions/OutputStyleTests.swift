import XCTest

@testable import DexCore

/// The picker has no table of its own — styles are files on disk and the CLI is
/// the only thing that can list them — so everything worth pinning here is about
/// what happens when that list is missing, short, or names something odd.
final class OutputStyleTests: XCTestCase {

    private let listed = ["default", "Proactive", "Concise", "Explanatory", "Learning", "ELI5"]

    /// The CLI lists its own word for having no style. Sending nothing already
    /// means that, so two rows would be two ways to say one thing.
    func testTheCLIsOwnDefaultRowIsNotOfferedTwice() {
        let offered = OutputStyle.offered(from: listed)
        XCTAssertEqual(offered.first, .inherited)
        XCTAssertEqual(offered.compactMap(\.label), Array(listed.dropFirst()))
    }

    /// An empty list is a host that has not run a session yet — the list lives
    /// on a running session's `initializationResult()` — so it is not evidence
    /// that a chosen style went away.
    func testAStyleSurvivesAListThatHasNotArrivedYet() {
        let offered = OutputStyle.offered(from: [], keeping: .named("ELI5"))
        XCTAssertEqual(offered, [.inherited, .named("ELI5")])
    }

    func testAStyleAlreadyOnTheListIsNotOfferedTwice() {
        let offered = OutputStyle.offered(from: listed, keeping: .named("Concise"))
        XCTAssertEqual(offered.filter { $0 == .named("Concise") }.count, 1)
    }

    /// `default` stored and nothing stored are the same answer: the picker has
    /// one row for it, and a session sends no style either way.
    func testTheCLIsDefaultReadsAsNoChoice() {
        XCTAssertEqual(OutputStyle(stored: "default"), .inherited)
        XCTAssertEqual(OutputStyle(stored: nil), .inherited)
        XCTAssertEqual(OutputStyle(stored: "  "), .inherited)
        XCTAssertNil(OutputStyle.inherited.hostStyleID)
    }

    /// These are names someone chose, in a file they wrote. Capitalising them is
    /// rewriting them.
    func testAStyleIsNamedExactlyAsTheCLIWritesIt() {
        XCTAssertEqual(OutputStyle.named("ELI5").menuLabel, "ELI5")
        XCTAssertEqual(OutputStyle.inherited.menuLabel, "Default")
        XCTAssertEqual(OutputStyle.named("ELI5").stored, "ELI5")
        XCTAssertEqual(OutputStyle.named("ELI5").hostStyleID, "ELI5")
    }
}
