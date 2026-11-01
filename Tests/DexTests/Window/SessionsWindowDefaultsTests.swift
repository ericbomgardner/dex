import XCTest
@testable import DexUI

final class SessionsWindowDefaultsTests: XCTestCase {

    private let key = "sessionsWindowOpen"

    /// A fresh install has never written the key. Read as false, the app came up
    /// as a menu bar item alone and the window had to be found.
    func testWindowOpensOnAFreshInstall() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: key)
        defer { defaults.set(saved, forKey: key) }

        defaults.removeObject(forKey: key)
        XCTAssertTrue(Defaults.sessionsWindowWasOpen)

        Defaults.sessionsWindowWasOpen = false
        XCTAssertFalse(Defaults.sessionsWindowWasOpen, "a window you closed stays closed")

        Defaults.sessionsWindowWasOpen = true
        XCTAssertTrue(Defaults.sessionsWindowWasOpen)
    }


    /// The default size has to leave room for the detail column at the width
    /// the list opens at, or the first open shows the list and nothing else.
    func testDefaultSizeShowsBothColumns() {
        XCTAssertGreaterThanOrEqual(
            SessionsWindow.defaultWidth - SessionsWindow.listInitialWidth,
            SessionPaneView.minWidth,
            "the detail column must open at least as wide as a pane needs"
        )
    }
}
