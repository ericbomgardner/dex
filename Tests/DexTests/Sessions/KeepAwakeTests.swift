import XCTest
@testable import DexUI
@testable import DexCore

final class KeepAwakeTests: XCTestCase {

    func testHeldWhileAHostedSessionWorks() {
        let rows = [makeRow("a", state: .running), makeRow("b", state: .done)]
        XCTAssertTrue(KeepAwake.shouldHold(rows: rows, live: ["a", "b"]))
    }

    func testReleasedWhenEverySessionIsIdle() {
        let rows = [makeRow("a", state: .done), makeRow("b", state: .idle)]
        XCTAssertFalse(KeepAwake.shouldHold(rows: rows, live: ["a", "b"]))
    }

    func testBackgroundWorkCounts() {
        let rows = [makeRow("a", state: .done, runningTasks: 1)]
        XCTAssertTrue(KeepAwake.shouldHold(rows: rows, live: ["a"]))
    }

    func testAnArchivedRowNeverHolds() {
        let rows = [makeRow("a", state: .done, owesTurn: true)]
        XCTAssertTrue(KeepAwake.shouldHold(rows: rows, live: ["a"]))
        XCTAssertFalse(KeepAwake.shouldHold(rows: rows, live: []),
                       "a file that ends mid-call with no host behind it would hold forever")
    }


    func testOnByDefault() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "keepsAwake")
        defer { defaults.set(saved, forKey: "keepsAwake") }

        defaults.removeObject(forKey: "keepsAwake")
        XCTAssertTrue(Defaults.keepsAwake)

        Defaults.keepsAwake = false
        XCTAssertFalse(Defaults.keepsAwake)
    }

    @MainActor
    func testAssertionIsHeldAndReleased() {
        let assertion = SleepAssertion()
        assertion.hold(true)
        XCTAssertTrue(assertion.isHeld)
        assertion.hold(false)
        XCTAssertFalse(assertion.isHeld)
    }
}
