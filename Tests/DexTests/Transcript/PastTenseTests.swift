import XCTest
@testable import DexCore

final class PastTenseTests: XCTestCase {

    /// The same table as transcript-render-test's, so the two readers agree.
    /// "CI logs, test output" is the rule's known miss: a noun after a comma
    /// that is more often a verb there.
    func testADescriptionIsSaidInThePast() {
        let cases = [
            ("Run the probe", "Ran the probe"),
            ("Re-run the probe", "Re-ran the probe"),
            ("Fast-forward main", "Fast-forwarded main"),
            ("Commit, merge and push", "Committed, merged and pushed"),
            ("Merge, then stamp the tip", "Merged, then stamped the tip"),
            ("Drop the stash and retry", "Dropped the stash and retried"),
            ("Read logs and callers", "Read logs and callers"),
            ("Latest logs from the host", "Latest logs from the host"),
            ("CI logs, test output", "CI logs, tested output"),
            ("Make it, see the result", "Made it, saw the result"),
            ("Show status, diff and log", "Showed status, diff and log"),
            ("Crop the screenshot and skim the log", "Cropped the screenshot and skimmed the log"),
            ("Fit the column, defer the reload", "Fit the column, deferred the reload"),
        ]
        for (given, said) in cases {
            XCTAssertEqual(PastTense.of(given), said, given)
        }
    }

    func testAnIrregularVerbIsNotAlsoRegular() {
        XCTAssertTrue(PastTense.doubled.isSubset(of: PastTense.regular))
        XCTAssertTrue(PastTense.irregular.keys.allSatisfy { !PastTense.regular.contains($0) })
    }
}
