import XCTest
@testable import DexCore

/// Which file's level a model starts at with nothing picked, by the CLI's rule
/// as of v2.1.280.
final class DefaultEffortTests: XCTestCase {

    private func defaults(_ efforts: [HostDefaults.EffortSource]?, merged: String? = "xhigh") -> HostDefaults {
        HostDefaults(cwd: "/p", outputStyle: nil, effort: merged, efforts: efforts)
    }

    /// The case that found this: `effortLevel: xhigh` saved in the user's file
    /// before `/effort` went per-model. Opus 5 still starts there; Opus 5.5
    /// starts at its own default, and the row must not say Xhigh for it.
    func testAUserLevelReachesOnlyTheOlderModels() {
        let resolved = defaults([.init(source: "user", effort: "xhigh")])
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5"), "xhigh")
        XCTAssertEqual(resolved.effort(forModel: "Fable 5.1"), "xhigh")
        XCTAssertNil(resolved.effort(forModel: "claude-opus-5-5"))
        XCTAssertNil(resolved.effort(forModel: "Opus 5.5"))
        XCTAssertEqual(resolved.effort(forModel: "claude-haiku-4-5"), "xhigh")
        XCTAssertNil(resolved.effort(forModel: "Haiku 5.5"))
    }

    func testAProjectLevelReachesEveryModel() {
        let resolved = defaults([
            .init(source: "project", effort: "low"),
            .init(source: "user", effort: "xhigh"),
        ])
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5-5"), "low")
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5"), "low")
    }

    func testAPerModelEntryBeatsItsOwnFilesTopLevel() {
        let resolved = defaults([
            .init(source: "user", effort: "xhigh", models: ["claude-opus-5-5": "medium"]),
        ])
        XCTAssertEqual(resolved.effort(forModel: "Opus 5.5"), "medium")
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5"), "xhigh")
    }

    /// Files are walked in precedence order and the first that answers wins,
    /// so a project's top-level beats a user's per-model entry.
    func testAHigherFileWinsWhateverShapeItAnswersIn() {
        let resolved = defaults([
            .init(source: "project", effort: "low"),
            .init(source: "user", models: ["claude-opus-5-5": "medium"]),
        ])
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5-5"), "low")
    }

    func testADatedOrWideIdMatchesItsEntry() {
        let resolved = defaults([.init(source: "user", models: ["claude-opus-5-5": "high"])])
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5-5[1m]"), "high")
    }

    func testMaxInAFileIsPassedOverForTheNextFile() {
        let resolved = defaults([
            .init(source: "local", effort: "max", models: ["claude-opus-5-5": "max"]),
            .init(source: "project", effort: "medium"),
        ])
        XCTAssertEqual(resolved.effort(forModel: "claude-opus-5-5"), "medium")
    }

    /// Before the CLI has named the model nothing model-dependent can be said,
    /// and sending nothing leaves the CLI to answer for itself.
    func testAnUnknownModelTakesOnlyWhatReachesEveryModel() {
        let resolved = defaults([
            .init(source: "user", effort: "xhigh", models: ["claude-opus-5-5": "medium"]),
        ])
        XCTAssertNil(resolved.effort(forModel: nil))
        XCTAssertEqual(
            defaults([.init(source: "local", effort: "low")]).effort(forModel: nil), "low"
        )
    }

    func testAHostFromBeforeTheFieldKeepsTheMergedAnswer() {
        XCTAssertEqual(defaults(nil).effort(forModel: "claude-opus-5-5"), "xhigh")
    }

    func testTheSourcesRoundTrip() throws {
        let json = #"{"cwd":"/p","outputStyle":null,"effort":"xhigh","efforts":[{"source":"user","effort":"xhigh","models":{"claude-opus-5-5":"low"}}]}"#
        let decoded = try JSONDecoder().decode(HostDefaults.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.efforts, [.init(source: "user", effort: "xhigh", models: ["claude-opus-5-5": "low"])])
        let again = try JSONDecoder().decode(HostDefaults.self, from: JSONEncoder().encode(decoded))
        XCTAssertEqual(again, decoded)
    }
}
