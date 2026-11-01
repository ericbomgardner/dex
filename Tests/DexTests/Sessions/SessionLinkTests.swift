import XCTest
@testable import DexCore

final class SessionLinkTests: XCTestCase {

    func testRoundTripsEveryField() {
        let link = SessionLink(
            sessionID: "3f2a9c1e-0000-4000-8000-000000000001",
            name: "Fix the cache & the \"retry\" bug",
            cwd: "/Users/me/Projects/My App"
        )
        XCTAssertEqual(SessionLink(url: link.url), link)
    }

    func testBareLinkHasNoQuery() {
        let link = SessionLink(sessionID: "abc")
        XCTAssertEqual(link.url.absoluteString, "dex://session/abc")
        XCTAssertEqual(SessionLink(url: link.url), link)
    }

    func testRejectsOtherSchemesHostsAndEmptyIDs() {
        XCTAssertNil(SessionLink(url: URL(string: "https://session/abc")!))
        XCTAssertNil(SessionLink(url: URL(string: "dex://project/abc")!))
        XCTAssertNil(SessionLink(url: URL(string: "dex://session/")!))
        XCTAssertNil(SessionLink(url: URL(string: "dex://session/a/b")!))
    }

    func testEmptyQueryValuesReadAsMissing() {
        let link = SessionLink(url: URL(string: "dex://session/abc?name=&cwd=/tmp")!)
        XCTAssertNil(link?.name)
        XCTAssertEqual(link?.cwd, "/tmp")
    }

    func testPastedLinkReadsBack() {
        let link = SessionLink(sessionID: "abc", name: "Plan the trip", cwd: "/Users/me/Projects/trip")
        XCTAssertEqual(SessionLink(pasted: link.url.absoluteString), link)
    }

    func testPastedTextAroundALinkIsNotALink() {
        XCTAssertNil(SessionLink(pasted: "see dex://session/abc"))
        XCTAssertNil(SessionLink(pasted: "https://example.com/session/abc"))
    }
}
