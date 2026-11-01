import XCTest
import DexCore
@testable import DexUI

final class ComposerEffortDefaultsTests: XCTestCase {

    /// The pick stays under the key it always had, so an upgrade keeps it.
    func testThePickKeepsItsKey() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "composerEffort")
        defer { defaults.set(saved, forKey: "composerEffort") }

        defaults.removeObject(forKey: "composerEffort")
        XCTAssertEqual(Defaults.composerEffort, .inherited)

        defaults.set("xhigh", forKey: "composerEffort")
        XCTAssertEqual(Defaults.composerEffort, .named("xhigh"))

        Defaults.composerEffort = .named("medium")
        XCTAssertEqual(defaults.string(forKey: "composerEffort"), "medium")
    }
}
