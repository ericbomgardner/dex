import XCTest

@testable import DexCore

final class McpTroubleTests: XCTestCase {

    private func call(_ id: String, _ name: String) -> String {
        #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{}}]}}"#
    }

    private func result(_ id: String, _ text: String, error: Bool) -> String {
        #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"\#(text)","is_error":\#(error)}]}}"#
    }

    private func calls(_ lines: String...) -> [String: McpCallOutcome]? {
        SessionDigestReader.digest(in: lines.map { Data($0.utf8) })?.mcpCalls
    }

    // Which errors are the server gone

    /// The texts mcp-drop-probe.ts gets back, CLI v2.1.296.
    func testTheCLIsTransportFailuresCount() {
        for text in [
            "Connection closed",
            "ECONNREFUSED: Unable to connect. Is the computer able to access the url?",
            "ECONNRESET: The socket connection was closed unexpectedly. For more information, pass `verbose: true` in the second argument to fetch()",
            #"MCP server "web" tool "hang" timed out after 4s"#,
            #"MCP server "web" session expired"#,
            "Error POSTing to endpoint: oops",
        ] {
            XCTAssertEqual(McpCallOutcome.reading(text, isError: true), .unreachable(text, at: nil), text)
        }
    }

    func testAToolsOwnErrorIsTheServerAnswering() {
        for text in [
            "No such issue: ABC-1", "internal kaboom", "Permission to use mcp__x__y has been denied.",
            "ENOENT: no such file or directory, open '/x'",
            "ECONNREFUSED: connect ECONNREFUSED 127.0.0.1:5432",
            "Connection closed by the database",
        ] {
            XCTAssertEqual(McpCallOutcome.reading(text, isError: true), .answered, text)
        }
        XCTAssertEqual(McpCallOutcome.reading("Connection closed", isError: false), .answered)
    }

    func testTheServerIsTheFirstPartOfTheToolName() {
        XCTAssertEqual(McpCallOutcome.server(ofTool: "mcp__claude_ai_Linear__get_issue"), "claude_ai_Linear")
        XCTAssertEqual(McpCallOutcome.server(ofTool: "mcp__web__ping"), "web")
        XCTAssertNil(McpCallOutcome.server(ofTool: "Bash"))
        XCTAssertNil(McpCallOutcome.server(ofTool: "mcp____x"))
    }

    // Off the transcript

    func testTheNewestCallToEachServerStands() {
        let read = calls(
            call("a", "mcp__web__ping"), result("a", "Connection closed", error: true),
            call("b", "mcp__web__ping"), result("b", "pong", error: false),
            call("c", "mcp__stdio__ping"), result("c", "Connection closed", error: true)
        )
        XCTAssertEqual(read, ["web": .answered, "stdio": .unreachable("Connection closed", at: nil)])
    }

    /// A result can be flushed before its call.
    func testAResultAheadOfItsCallStillCounts() {
        XCTAssertEqual(calls(result("a", "Connection closed", error: true), call("a", "mcp__web__ping")),
                       ["web": .unreachable("Connection closed", at: nil)])
    }

    func testAWindowWithNoMcpCallsSaysNothing() {
        XCTAssertNil(calls(call("a", "Bash"), result("a", "Connection closed", error: true)))
        XCTAssertNil(calls(call("a", "mcp__web__ping")))
    }

    func testALaterWindowOnlyMovesTheServersItSaw() {
        let earlier = SessionDigest(mcpCalls: ["web": .unreachable("Connection closed", at: nil), "stdio": .answered])
        let later = SessionDigest(mcpCalls: ["web": .answered])
        XCTAssertEqual(later.merged(over: earlier).mcpCalls, ["web": .answered, "stdio": .answered])
        XCTAssertEqual(SessionDigest().merged(over: earlier).mcpCalls, earlier.mcpCalls)
    }

    // On the row

    func testStartupTroubleAndDroppedCallsTogether() {
        let trouble = McpTrouble.of(
            servers: [HostMcpServer(name: "claude.ai Linear", status: "connected"),
                      HostMcpServer(name: "notes", status: "failed", error: "ECONNREFUSED"),
                      HostMcpServer(name: "notion", status: "needs-auth"),
                      HostMcpServer(name: "memory", status: "pending")],
            calls: ["claude_ai_Linear": .unreachable("Connection closed", at: nil), "memory": .answered])
        XCTAssertEqual(trouble, [
            McpTrouble(server: "notes", kind: .failed, detail: "ECONNREFUSED"),
            McpTrouble(server: "notion", kind: .needsAuth, detail: nil),
            McpTrouble(server: "claude.ai Linear", kind: .unreachable, detail: "Connection closed"),
        ])
    }

    /// A resume reuses the file, and the drop it ends on was the last process's.
    func testADropFromBeforeThisProcessIsLeftOut() {
        let start = Date(timeIntervalSince1970: 1_000)
        let calls: [String: McpCallOutcome] = [
            "old": .unreachable("Connection closed", at: start.addingTimeInterval(-1)),
            "new": .unreachable("Connection closed", at: start.addingTimeInterval(1)),
        ]
        XCTAssertEqual(McpTrouble.of(servers: nil, calls: calls, since: start).map(\.server), ["new"])
    }

    func testTheResultsTimestampIsKept() {
        let stamped = #"{"type":"user","timestamp":"2026-10-11T01:39:19.916Z","message":{"content":[{"type":"tool_result","tool_use_id":"a","content":"Connection closed","is_error":true}]}}"#
        guard case .unreachable(_, let at)? = calls(call("a", "mcp__web__ping"), stamped)?["web"] else { return XCTFail() }
        XCTAssertNotNil(at)
    }

    /// Two parallel calls, in the order CLI v2.1.300 writes them (api-request-record-probe.ts).
    func testARequestBlobRepeatingTheResultsIsNotATurn() {
        let first = #"{"type":"user","timestamp":"2026-10-15T08:19:26.052Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"Connection closed","is_error":true}]}}"#
        let second = #"{"type":"user","timestamp":"2026-10-15T08:19:26.060Z","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"b","content":"pong"}]}}"#
        let blob = #"{"type":"api-request-blob","hash":"b2da","sessionId":"s","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"a","content":"Connection closed","is_error":true},{"type":"tool_result","tool_use_id":"b","content":"pong"}]}}"#
        let request = #"{"type":"api-request","id":"r","timestamp":"2026-10-15T08:19:27.000Z","tail":["b2da"]}"#
        let read = calls(call("a", "mcp__web__ping"), call("b", "mcp__db__ping"), first, second, blob, request)
        guard case .unreachable(_, let at)? = read?["web"] else { return XCTFail() }
        XCTAssertEqual(at, TranscriptTimestamp.parse("2026-10-15T08:19:26.052Z"))
    }

    func testAServerAlreadyFailedIsNamedOnce() {
        let trouble = McpTrouble.of(servers: [HostMcpServer(name: "notes", status: "failed")],
                                    calls: ["notes": .unreachable("Connection closed", at: nil)])
        XCTAssertEqual(trouble.map(\.kind), [.failed])
    }

    func testNoHostReadingStillShowsDroppedCalls() {
        XCTAssertEqual(McpTrouble.of(servers: nil, calls: ["web": .unreachable("Connection closed", at: nil)]).map(\.server), ["web"])
    }

    func testAReconnectClearsTheDropBeforeItButNotAfter() {
        let mended = Date(timeIntervalSince1970: 1_000)
        let calls: [String: McpCallOutcome] = [
            "claude_ai_Linear": .unreachable("Connection closed", at: mended.addingTimeInterval(-1)),
            "web": .unreachable("Connection closed", at: mended.addingTimeInterval(1)),
        ]
        let trouble = McpTrouble.of(
            servers: nil, calls: calls, reconnected: ["claude.ai Linear": mended, "web": mended])
        XCTAssertEqual(trouble.map(\.server), ["web"])
    }

    func testAReconnectClearsTheDropItWasPressedOn() {
        let at = Date(timeIntervalSince1970: 1_000)
        let calls: [String: McpCallOutcome] = ["web": .unreachable("Connection closed", at: at)]
        let found = McpTrouble.of(servers: nil, calls: calls)
        XCTAssertEqual(found.first?.droppedAt, at)
        XCTAssertEqual(McpTrouble.of(servers: nil, calls: calls, reconnected: ["web": at]), [])
    }

    func testAReconnectClearsAnUnstampedDrop() {
        let trouble = McpTrouble.of(
            servers: nil, calls: ["web": .unreachable("Connection closed", at: nil)], reconnected: ["web": .distantPast])
        XCTAssertEqual(trouble, [])
    }
}
