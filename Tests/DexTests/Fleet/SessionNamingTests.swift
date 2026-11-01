import XCTest
@testable import DexCore

final class SessionNamingTests: XCTestCase {

    func testNamesASessionTheCLIStillCallsByItsFolder() {
        let renames = SessionNaming.renames(
            [makeRow("Fix the loader", state: .running)],
            registry: ["uuid-Fix the loader": .init(address: "sketch-67", isDerived: true)]
        )

        XCTAssertEqual(renames, [.init(sessionId: "uuid-Fix the loader", title: "Fix the loader")])
    }

    func testLeavesANameSomeoneChose() {
        let renames = SessionNaming.renames(
            [makeRow("Fix the loader", state: .running)],
            registry: ["uuid-Fix the loader": .init(address: "Loader work")]
        )

        XCTAssertEqual(renames, [])
    }

    /// Not running means not in the registry, and nothing there to rename.
    func testLeavesASessionTheRegistryDoesNotHold() {
        XCTAssertEqual(SessionNaming.renames([makeRow("Stopped", state: .done)], registry: [:]), [])
    }

    func testWaitsForATitle() {
        let commanded = makeRow("/review 12", state: .running)
        let untitled = SessionRowModel(
            session: AgentSession(
                cwd: "/repo", startedAt: 0, hostKey: "k",
                state: .running,
                sessionId: "uuid-untitled", name: nil
            )
        )

        let renames = SessionNaming.renames(
            [commanded, untitled],
            registry: [
                "uuid-/review 12": .init(address: "repo-1a", isDerived: true),
                "uuid-untitled": .init(address: "repo-2b", isDerived: true),
            ]
        )

        XCTAssertEqual(renames, [])
    }
}
