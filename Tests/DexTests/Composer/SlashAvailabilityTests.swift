import XCTest
@testable import DexUI
@testable import DexCore

final class SlashAvailabilityTests: XCTestCase {

    private let catalogue = [
        Command(name: "config", summary: "Open settings"),
        Command(name: "context", summary: "Visualize current context usage"),
        Command(name: "help", summary: "Show help and available commands"),
        Command(name: "resume", summary: "Resume a conversation"),
        Command(name: "ship", summary: "Merge and push", isCustom: true),
    ]

    func testACommandTheSessionNamesStaysOnOffer() {
        let marked = SlashCommands.marked(catalogue, live: ["config", "context", "ship"])

        XCTAssertEqual(marked.first { $0.name == "config" }?.isAvailable, true)
        XCTAssertEqual(marked.first { $0.name == "ship" }?.isAvailable, true)
    }

    func testOneItDoesNotNameIsGreyedRatherThanDropped() {
        let marked = SlashCommands.marked(catalogue, live: ["config"])

        XCTAssertEqual(marked.count, catalogue.count)
        XCTAssertEqual(marked.first { $0.name == "help" }?.isAvailable, false)
        XCTAssertEqual(marked.first { $0.name == "resume" }?.isAvailable, false)
    }

    /// A command written to disk mid-session is one the catalogue can see and
    /// the running CLI cannot.
    func testACustomCommandIsStampedLikeTheRest() {
        let marked = SlashCommands.marked(catalogue, live: ["config"])

        XCTAssertEqual(marked.first { $0.name == "ship" }?.isAvailable, false)
    }

    func testNobodyHavingSaidLeavesEverythingOnOffer() {
        XCTAssertEqual(SlashCommands.marked(catalogue, live: nil), catalogue)
    }

    /// Empty is a session saying it runs nothing, which is a different thing
    /// from one that has not said — and the reason the host sends null rather
    /// than `[]` for a session it has not heard an `init` from.
    func testASessionThatRunsNothingIsNotTheSameAsOneThatHasNotSaid() {
        XCTAssertTrue(SlashCommands.marked(catalogue, live: []).allSatisfy { !$0.isAvailable })
    }

    /// The list is the running CLI's whole dispatch table and carries
    /// housekeeping nobody types.
    func testANameTheCatalogueHasNotGotIsNotAddedToIt() {
        let marked = SlashCommands.marked(catalogue, live: ["config", "heapdump"])

        XCTAssertEqual(marked.map(\.name), catalogue.map(\.name))
    }

    /// `/reload-skills` grows the list mid-session, and a row greyed by the
    /// reading before it has to come back.
    func testAGreyedCommandComesBackWhenTheSessionNamesIt() {
        let greyed = SlashCommands.marked(catalogue, live: ["config"])
        let again = SlashCommands.marked(greyed, live: ["config", "ship"])

        XCTAssertEqual(again.first { $0.name == "ship" }?.isAvailable, true)
    }
}

@MainActor
final class SlashMenuAvailabilityTests: XCTestCase {

    private func menu(runs: [String]?) -> SlashMenu {
        let menu = SlashMenu(catalogue: [
            Command(name: "config", summary: "Open settings"),
            Command(name: "context", summary: "Visualize current context usage"),
            Command(name: "copy", summary: "Copy Claude's last response"),
            Command(name: "cost", summary: "Show total cost"),
        ])
        menu.sessionRuns(runs)
        return menu
    }

    func testTheCursorStartsOnARowTheSessionWouldRun() {
        let menu = menu(runs: ["copy"])
        menu.draftChanged(to: "/co")

        XCTAssertEqual(menu.selected?.name, "copy")
    }

    func testEnterTakesNothingFromAGreyedRow() {
        let menu = menu(runs: [])
        menu.draftChanged(to: "/co")

        XCTAssertTrue(menu.isOpen)
        XCTAssertNil(menu.selected)
    }

    func testTheArrowsStepOverTheRowsItWouldNotRun() {
        let menu = menu(runs: ["config", "cost"])
        menu.draftChanged(to: "/co")

        let first = menu.selected?.name
        menu.move(1)
        let second = menu.selected?.name

        XCTAssertEqual(Set([first, second].compactMap { $0 }), ["config", "cost"])
        menu.move(1)
        XCTAssertEqual(menu.selected?.name, first)
    }

    func testWithNothingTakeableTheArrowsDoNotSpin() {
        let menu = menu(runs: [])
        menu.draftChanged(to: "/co")
        let before = menu.selection

        menu.move(1)

        XCTAssertEqual(menu.selection, before)
    }

    /// `init` arrives once a turn, so the first one can land while the menu is
    /// already on screen.
    func testAListArrivingUnderAnOpenMenuGreysIt() {
        let menu = menu(runs: nil)
        menu.draftChanged(to: "/co")
        XCTAssertEqual(menu.matches.filter(\.isAvailable).count, 4)

        menu.sessionRuns(["cost"])

        XCTAssertEqual(menu.matches.filter(\.isAvailable).map(\.name), ["cost"])
        XCTAssertEqual(menu.selected?.name, "cost")
    }

    func testASessionWithNoHostBehindItOffersEverything() {
        let menu = menu(runs: nil)
        menu.draftChanged(to: "/co")

        XCTAssertTrue(menu.matches.allSatisfy(\.isAvailable))
        XCTAssertNotNil(menu.selected)
    }
}
