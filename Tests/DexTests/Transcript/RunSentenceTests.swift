import XCTest
@testable import DexCore

final class RunSentenceTests: XCTestCase {

    private var nextID = 0

    private func call(
        _ name: String,
        _ input: [String: String] = [:],
        failed: Bool = false,
        result: Bool = true
    ) -> ToolCall {
        nextID += 1
        return ToolCall(
            id: "c\(nextID)",
            name: name,
            input: .object(input.mapValues { .string($0) }),
            result: result ? ToolResult(text: failed ? "boom" : "ok", isError: failed) : nil
        )
    }

    /// The same case as transcript-render-test's, so the two readers agree.
    func testARunReadsAsOneSentenceOfWhatWasDone() {
        let calls = [
            call("Read", ["file_path": "/x/A.swift"]),
            call("Read", ["file_path": "/x/B.swift"]),
            call("Read", ["file_path": "/x/C.swift"]),
            call("Grep", ["pattern": "atEnd"]),
            call("Bash", [
                "command": "cd /Users/me/Projects/x && swift build 2>&1 | grep -E 'error|warning' | head -40",
                "description": "Build and show errors",
            ]),
            call("mcp__dex__list_sessions"),
        ]
        XCTAssertEqual(
            RunSentence.of(calls),
            "Read A.swift and 2 others, searched for “atEnd”, built and showed errors, called list_sessions (dex)"
        )
    }

    func testAFailureIsSaidBesideWhatFailed() {
        let calls = [
            call("Read", ["file_path": "/Users/me/Projects/x/Sources/A.swift"]),
            call("Bash", ["command": "swift test\n# more"], failed: true),
        ]
        XCTAssertEqual(RunSentence.of(calls), "Read A.swift, ran swift test (failed)")
    }

    func testTheSameFileReadTwiceIsNamedOnce() {
        let calls = [
            call("Read", ["file_path": "/x/A.swift"]),
            call("Read", ["file_path": "/x/A.swift"]),
            call("Edit", ["file_path": "/x/A.swift"]),
            call("Edit", ["file_path": "/x/B.swift"]),
        ]
        XCTAssertEqual(RunSentence.of(calls), "Read A.swift, edited A.swift and B.swift")
    }

    /// A call the session died under is "never came back" on the row, not a
    /// failure in the sentence.
    func testAnUnrecordedResultIsNotAFailure() {
        let lost = ToolCall(
            id: "lost", name: "Read", input: .object(["file_path": .string("/x/A.swift")]),
            result: ToolResult(
                text: "[Tool call interrupted: the session ended before this call's result was recorded]",
                isError: true
            )
        )
        XCTAssertEqual(RunSentence.of([lost]), "Read A.swift")
    }

    /// Descriptions are clauses already, so they never share an "and", and a
    /// failure folded away is still counted.
    func testDescribedCommandsFoldWithTheirFailuresCounted() {
        let heredoc = "python3 - <<'EOF'\nprint(1)\nEOF"
        let two = [
            call("Bash", ["command": heredoc, "description": "Find uses and callers"]),
            call("Bash", ["command": heredoc, "description": "Check imports"], failed: true),
        ]
        XCTAssertEqual(RunSentence.of(two), "Found uses and callers, checked imports (failed)")
        let four = two + [
            call("Bash", ["command": heredoc, "description": "Read the notes"], failed: true),
            call("Bash", ["command": heredoc, "description": "List files"]),
        ]
        XCTAssertEqual(RunSentence.of(four), "Found uses and callers and 3 more commands (2 failed)")
    }

    func testADescriptionOpeningOnAnAcronymKeepsItsCase() {
        let calls = [
            call("Read", ["file_path": "/x/A.swift"]),
            call("Bash", ["command": "gh run view\n--log", "description": "CI logs for <run>"]),
            call("WebFetch", ["url": "https://GitHub.com:443/x"]),
        ]
        XCTAssertEqual(RunSentence.of(calls), "Read A.swift, CI logs for <run>, fetched GitHub.com")
    }

    func testALongCommandWithNoDescriptionIsCut() {
        let calls = [call("Bash", ["command": String(repeating: "x", count: 50)])]
        XCTAssertEqual(RunSentence.of(calls), "Ran \(String(repeating: "x", count: 40))…")
    }
}
