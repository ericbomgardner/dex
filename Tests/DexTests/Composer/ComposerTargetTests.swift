import XCTest
@testable import DexCore

final class ComposerTargetTests: XCTestCase {
    private let home = "/Users/test"

    private func row(_ name: String, cwd: String, startedAt: Double) -> SessionRowModel {
        makeRow(name, state: .done, startedAt: startedAt, cwd: cwd)
    }

    private func resolve(
        selected: String? = nil,
        lastUsed: String? = nil,
        rows: [SessionRowModel] = [],
        exists: @escaping (String) -> Bool = { _ in true }
    ) -> String {
        ComposerTarget.resolve(
            selectedProject: selected,
            lastUsed: lastUsed,
            rows: rows,
            home: home,
            directoryExists: exists
        )
    }

    func testSelectedProjectTakesPrecedence() {
        XCTAssertEqual(
            resolve(selected: "/p/alpha", lastUsed: "/p/beta",
                    rows: [row("r", cwd: "/p/gamma", startedAt: 9_000)]),
            "/p/alpha"
        )
    }

    func testFallsBackToTheLastDirectoryDispatchedInto() {
        XCTAssertEqual(
            resolve(lastUsed: "/p/beta", rows: [row("r", cwd: "/p/gamma", startedAt: 9_000)]),
            "/p/beta"
        )
    }

    func testAMissingRememberedDirectoryIsSkipped() {
        let target = resolve(
            lastUsed: "/p/deleted",
            rows: [row("r", cwd: "/p/gamma", startedAt: 9_000)],
            exists: { $0 != "/p/deleted" }
        )
        XCTAssertEqual(target, "/p/gamma")
    }

    func testFallsBackToTheMostRecentlyStartedSession() {
        let target = resolve(rows: [
            row("old", cwd: "/p/old", startedAt: 1_000),
            row("newest", cwd: "/p/newest", startedAt: 9_000),
            row("middle", cwd: "/p/middle", startedAt: 5_000),
        ])
        XCTAssertEqual(target, "/p/newest")
    }

    func testFallsBackToHomeWithNoOtherCandidate() {
        XCTAssertEqual(resolve(), home)
    }

    func testEmptyStringsAreTreatedAsAbsent() {
        XCTAssertEqual(resolve(selected: "", lastUsed: ""), home)
    }

    private func picked(
        selected: String? = nil,
        lastUsed: String? = nil,
        rows: [SessionRowModel] = [],
        exists: @escaping (String) -> Bool = { _ in true }
    ) -> String? {
        ComposerTarget.picked(selectedProject: selected, lastUsed: lastUsed,
                              rows: rows, directoryExists: exists)
    }

    func testTheHomeFallbackIsNotAPickedFolder() {
        XCTAssertNil(picked())
        XCTAssertNil(picked(selected: "", lastUsed: ""))
        XCTAssertNil(picked(lastUsed: "/p/deleted", exists: { $0 != "/p/deleted" }))
    }

    func testEveryOtherCandidateCountsAsPicked() {
        XCTAssertEqual(picked(selected: "/p/alpha", lastUsed: "/p/beta"), "/p/alpha")
        XCTAssertEqual(picked(lastUsed: "/p/beta"), "/p/beta")
        XCTAssertEqual(picked(rows: [row("r", cwd: "/p/gamma", startedAt: 9_000)]), "/p/gamma")
    }

    func testAFilteredListPinsTheTarget() {
        XCTAssertEqual(ComposerTarget.pinned(to: "/p/alpha"), "/p/alpha")
    }

    func testNothingIsPinnedWithoutAProjectFilter() {
        XCTAssertNil(ComposerTarget.pinned(to: nil))
        XCTAssertNil(ComposerTarget.pinned(to: ""))
    }

    func testTargetNameComesFromTheProjectList() {
        let projects = ProjectIndex.summaries(for: [
            row("a", cwd: "/x/orchard/memory", startedAt: 1),
            row("b", cwd: "/y/atlas/memory", startedAt: 2),
        ])

        XCTAssertEqual(ComposerTarget.name(for: "/x/orchard/memory", in: projects), "orchard/memory")
    }

    func testUnknownDirectoryFallsBackToItsLeaf() {
        XCTAssertEqual(ComposerTarget.name(for: "/p/brand-new", in: []), "brand-new")
    }

    /// The picker names a project before the first load and again after, so the
    /// two answers have to agree or the label rewrites itself at launch.
    func testTheNameIsUnchangedWhenTheFirstLoadArrives() {
        let path = "/Users/test/Projects/copper-agents-worker"
        let loaded = ProjectIndex.summaries(for: [row("a", cwd: path, startedAt: 1)])

        XCTAssertEqual(ComposerTarget.name(for: path, in: []),
                       ComposerTarget.name(for: path, in: loaded))
        XCTAssertEqual(ComposerTarget.name(for: path, in: loaded), "copper-agents-worker")
    }
}
