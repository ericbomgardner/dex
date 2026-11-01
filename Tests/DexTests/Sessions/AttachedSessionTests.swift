import XCTest
@testable import DexCore

final class AttachedSessionTests: XCTestCase {

    private let row = makeRow("attached", state: .done, cwd: "/p/alpha")

    private func isOutOfView(
        project: String? = nil,
        resolutions: SessionResolutions = SessionResolutions()
    ) -> Bool {
        AttachedSession.isOutOfView(row, project: project, resolutions: resolutions)
    }

    func testAnUnfilteredListKeepsTheSessionAttached() {
        XCTAssertFalse(isOutOfView())
        XCTAssertFalse(isOutOfView(project: ""))
    }

    func testFilteringToItsOwnProjectKeepsItAttached() {
        XCTAssertFalse(isOutOfView(project: "/p/alpha"))
    }

    func testFilteringToAnotherProjectTakesItOffScreen() {
        XCTAssertTrue(isOutOfView(project: "/p/beta"))
    }

    func testResolvingItTakesItOffScreen() {
        var resolutions = SessionResolutions()
        resolutions.resolve(row)

        XCTAssertTrue(isOutOfView(resolutions: resolutions))
        XCTAssertTrue(isOutOfView(project: "/p/alpha", resolutions: resolutions))
    }

    func testUnresolvingItBringsItBack() {
        var resolutions = SessionResolutions()
        resolutions.resolve(row)
        resolutions.clear(row)

        XCTAssertFalse(isOutOfView(resolutions: resolutions))
    }
}
