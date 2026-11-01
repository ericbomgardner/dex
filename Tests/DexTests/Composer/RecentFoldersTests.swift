import XCTest
@testable import DexCore

final class RecentFoldersTests: XCTestCase {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    func testNotingAFolderRecordsWhen() {
        var recents = RecentFolders()
        recents.note("/p/alpha", at: at(100))
        XCTAssertEqual(recents.lastUsed["/p/alpha"], at(100))
    }

    func testNotingAgainMovesTheClock() {
        var recents = RecentFolders()
        recents.note("/p/alpha", at: at(100))
        recents.note("/p/alpha", at: at(200))
        XCTAssertEqual(recents.lastUsed, ["/p/alpha": at(200)])
    }

    func testAnEmptyPathIsIgnored() {
        var recents = RecentFolders()
        recents.note("", at: at(100))
        XCTAssertTrue(recents.isEmpty)
    }

    func testTheOldestFallOffPastTheCap() {
        var recents = RecentFolders()
        for index in 0...RecentFolders.capacity {
            recents.note("/p/\(index)", at: at(Double(index)))
        }
        XCTAssertEqual(recents.lastUsed.count, RecentFolders.capacity)
        XCTAssertFalse(recents.contains("/p/0"))
        XCTAssertTrue(recents.contains("/p/\(RecentFolders.capacity)"))
    }

    func testPruningForgetsFoldersThatAreGone() {
        var recents = RecentFolders(["/p/deleted": at(100), "/p/alpha": at(50)])
        recents.prune(keeping: { $0 != "/p/deleted" })
        XCTAssertEqual(recents.paths, ["/p/alpha"])
    }

    func testSurvivesARoundTrip() throws {
        var recents = RecentFolders()
        recents.note("/p/alpha", at: at(100))
        let data = try JSONEncoder().encode(recents)
        XCTAssertEqual(try JSONDecoder().decode(RecentFolders.self, from: data), recents)
    }
}

final class ComposerFoldersTests: XCTestCase {
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }

    private func row(_ name: String, cwd: String, updatedAt: Double) -> SessionRowModel {
        makeRow(name, state: .done, startedAt: updatedAt * 1000, cwd: cwd)
    }

    private func list(
        rows: [SessionRowModel] = [],
        recents: [String: Date] = [:]
    ) -> [ProjectSummary] {
        ComposerFolders.list(rows: rows, recents: RecentFolders(recents))
    }

    func testAFolderPickedBeforeIsListedWithoutASession() {
        let folders = list(recents: ["/p/alpha": at(100)])
        XCTAssertEqual(folders.map(\.path), ["/p/alpha"])
        XCTAssertEqual(folders.first?.total, 0)
        XCTAssertEqual(folders.first?.name, "alpha")
    }

    func testSessionsAndPicksSortTogetherNewestFirst() {
        let folders = list(
            rows: [
                row("old", cwd: "/p/sessions-old", updatedAt: 100),
                row("new", cwd: "/p/sessions-new", updatedAt: 300),
            ],
            recents: ["/p/picked": at(200)]
        )
        XCTAssertEqual(folders.map(\.path), ["/p/sessions-new", "/p/picked", "/p/sessions-old"])
    }

    func testAProjectWithSessionsKeepsItsCounts() {
        let folders = list(
            rows: [row("a", cwd: "/p/alpha", updatedAt: 100), row("b", cwd: "/p/alpha", updatedAt: 200)],
            recents: ["/p/alpha": at(50)]
        )
        XCTAssertEqual(folders.count, 1)
        XCTAssertEqual(folders.first?.total, 2)
    }

    func testAPickAfterTheLastSessionOutranksIt() {
        let folders = list(
            rows: [row("a", cwd: "/p/alpha", updatedAt: 300), row("b", cwd: "/p/beta", updatedAt: 100)],
            recents: ["/p/beta": at(400)]
        )
        XCTAssertEqual(folders.map(\.path), ["/p/beta", "/p/alpha"])
    }

    func testCollidingLeavesAreToldApartAcrossBothSources() {
        let folders = list(
            rows: [row("a", cwd: "/work/x/app", updatedAt: 200)],
            recents: ["/home/y/app": at(100)]
        )
        XCTAssertEqual(folders.map(\.name), ["x/app", "y/app"])
    }

    func testNothingToOfferIsAnEmptyList() {
        XCTAssertTrue(list().isEmpty)
    }
}
