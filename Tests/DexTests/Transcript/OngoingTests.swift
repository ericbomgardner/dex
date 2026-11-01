import XCTest
@testable import DexCore

final class OngoingTests: XCTestCase {

    func testADescriptionIsSaidAsHappening() {
        let cases = [
            ("Run the test suite", "Running the test suite"),
            ("Re-run the probe", "Re-running the probe"),
            ("Commit, merge and push", "Committing, merging and pushing"),
            ("Build and show errors", "Building and showing errors"),
            ("Make it, see the result", "Making it, seeing the result"),
            ("Use the cache, then set the flag", "Using the cache, then setting the flag"),
            ("Type-check and run summary tests", "Type-checking and running summary tests"),
            ("Defer the reload", "Deferring the reload"),
            ("Do a dry run", "Doing a dry run"),
            ("Show status, diff and log", "Showing status, diff and log"),
            ("Latest logs from the host", "Latest logs from the host"),
        ]
        for (given, said) in cases {
            XCTAssertEqual(Ongoing.of(given), said, given)
        }
    }

    func testEveryVerbItDoublesIsOneItKnows() {
        XCTAssertTrue(Ongoing.doubled.allSatisfy { PastTense.irregular[$0] != nil })
    }
}
