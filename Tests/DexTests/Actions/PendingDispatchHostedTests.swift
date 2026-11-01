import XCTest

@testable import DexCore

/// A dispatch is claimed by `rowID`, which is the host's key for the session.
final class PendingDispatchHostedTests: XCTestCase {

    private func hostedRow(key: String, cwd: String = "/tmp/work") -> SessionRowModel {
        SessionRowModel(
            hosted: HostSessionSummary(
                key: key,
                sessionId: "uuid-\(key)",
                cwd: cwd,
                name: key,
                state: .running,
                model: nil,
                permissionMode: "default",
                startedAt: "2026-08-11T00:00:00Z"
            ),
            hostPID: 4242
        )
    }

    func testARowIsClaimedByItsHostKey() {
        let pending = PendingDispatch(
            prompt: "go", project: "/tmp/work", rowID: "k1", knownRowIDs: []
        )
        let rows = [hostedRow(key: "other"), hostedRow(key: "k1")]

        XCTAssertEqual(pending.matchingRow(in: rows)?.rowID, "k1")
    }

    func testARowAlreadyThereIsNotTheOneTheDispatchStarted() {
        let pending = PendingDispatch(
            prompt: "go", project: "/tmp/work", knownRowIDs: ["k1"]
        )
        let rows = [hostedRow(key: "k1"), hostedRow(key: "k2")]

        XCTAssertEqual(pending.matchingRow(in: rows)?.rowID, "k2")
    }

    /// The two are on screen one after the other over about a second, so what
    /// the placeholder says has to be what the row it becomes says: the same
    /// title in the title, and what was typed in the line the session's own
    /// last message takes over.
    func testThePlaceholderReadsLikeTheRowItBecomes() {
        let pending = PendingDispatch(
            prompt: "  fix the\n  row titles  ", project: "/tmp/work", knownRowIDs: []
        )

        XCTAssertEqual(pending.title, AgentSession.unnamed)
        XCTAssertEqual(pending.opening, "fix the row titles")
        XCTAssertEqual(
            pending.opening,
            SessionDigestReader.oneLine("  fix the\n  row titles  "),
            "the line must be folded the way the file's own is, or it reflows when the file answers"
        )
    }

    func testAnEmptyPromptHasNoOpeningLine() {
        let pending = PendingDispatch(prompt: "   ", project: "/tmp/work", knownRowIDs: [])
        XCTAssertNil(pending.opening)
    }
}
