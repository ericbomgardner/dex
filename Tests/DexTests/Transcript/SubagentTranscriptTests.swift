import XCTest
@testable import DexCore

/// Where a subagent's conversation is, given the call that set it off. Pinned
/// against **CLI v2.1.227** — a layout change here reads as a session that never
/// delegated, since every row simply stops opening.
final class SubagentTranscriptTests: XCTestCase {

    private let parent = URL(
        fileURLWithPath: "/Users/e/.claude/projects/-Users-e-app/9f89eac9-558f.jsonl"
    )

    func testAgentsWriteBesideTheirSessionsTranscript() throws {
        let directory = try XCTUnwrap(SubagentTranscript.directory(besideParent: parent))
        XCTAssertEqual(
            directory.path,
            "/Users/e/.claude/projects/-Users-e-app/9f89eac9-558f/subagents"
        )
    }

    func testAPathThatIsNotATranscriptHasNoAgents() {
        XCTAssertNil(
            SubagentTranscript.directory(
                besideParent: URL(fileURLWithPath: "/Users/e/.claude/projects/-Users-e-app")
            )
        )
    }

    func testFindsTheFileAnAgentWrote() throws {
        let directory = try scratch()
        let file = directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl")
        try Data("{}\n".utf8).write(to: file)

        XCTAssertEqual(
            SubagentTranscript.locate(agentID: "a3c7e19b04f2d6a58", in: directory)?.path,
            file.path
        )
    }

    /// An agent is named in its receipt before it opens its file, so the gap
    /// between launching and starting is answered with nil rather than a path
    /// that isn't there yet.
    func testAnAgentThatHasNotStartedHasNoTranscript() throws {
        let directory = try scratch()
        XCTAssertNil(SubagentTranscript.locate(agentID: "a3c7e19b04f2d6a58", in: directory))
    }

    /// Nested agents land in the same flat directory rather than under their own
    /// parent, which is what lets a depth-3 agent be found the same way a
    /// depth-1 one is.
    func testNestedAgentsShareOneDirectory() throws {
        let directory = try scratch()
        for id in ["a23de8ca9f08861d6", "a8e869357bf1fca53"] {
            try Data("{}\n".utf8).write(
                to: directory.appendingPathComponent("agent-\(id).jsonl")
            )
        }

        XCTAssertNotNil(SubagentTranscript.locate(agentID: "a23de8ca9f08861d6", in: directory))
        XCTAssertNotNil(SubagentTranscript.locate(agentID: "a8e869357bf1fca53", in: directory))
    }

    /// The whole chain the pane runs when a row is opened — find the file, read
    /// it, and turn it into the same items the conversation above it is drawn
    /// from. Written in the shape a real agent file has: every record sidechain,
    /// an opening prompt whose content is a bare string, then thinking, calls
    /// and replies.
    func testAnAgentsFileReadsAsAConversation() throws {
        let directory = try scratch()
        let records = [
            #"{"type":"user","uuid":"u1","isSidechain":true,"message":{"content":"Review the diff"}}"#,
            #"{"type":"assistant","uuid":"a1","isSidechain":true,"message":{"content":[{"type":"thinking","thinking":"Start with the diff."}]}}"#,
            #"{"type":"assistant","uuid":"a2","isSidechain":true,"message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git diff"}}]}}"#,
            #"{"type":"user","uuid":"u2","isSidechain":true,"message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"two files changed"}]}}"#,
            #"{"type":"assistant","uuid":"a3","isSidechain":true,"message":{"content":[{"type":"text","text":"Three findings."}]}}"#,
        ]
        let file = directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl")
        try Data((records.joined(separator: "\n") + "\n").utf8).write(to: file)

        let located = try XCTUnwrap(
            SubagentTranscript.locate(agentID: "a3c7e19b04f2d6a58", in: directory)
        )
        var tail = TranscriptTail(url: located)
        var document = TranscriptDocument(keepsSidechain: true)
        for line in tail.read().lines { document.append(line: line) }

        let items = TranscriptFlow.items(from: document.entries)
        XCTAssertEqual(
            items.map(\.id).map { String($0.prefix(while: { $0 != ":" })) },
            ["prompt", "think", "run", "reply"]
        )

        guard case .toolRun(let run) = items[2] else { return XCTFail("expected the call") }
        XCTAssertEqual(run.calls.first?.result?.text, "two files changed")
    }

    private func agentTurn(_ uuid: String, cacheRead: Int) -> String {
        """
        {"type":"assistant","uuid":"\(uuid)","isSidechain":true,"agentId":"a3c7e19b04f2d6a58",\
        "message":{"role":"assistant","model":"claude-opus-5-5","content":[{"type":"text","text":"ok"}],\
        "usage":{"input_tokens":3,"cache_read_input_tokens":\(cacheRead),\
        "cache_creation_input_tokens":0,"output_tokens":40}}}
        """
    }

    /// Every record in an agent's file is a sidechain one, and its context is
    /// its own conversation's, so they are read rather than skipped as they
    /// are in the parent's digest.
    func testAnAgentCarriesItsNewestTurn() throws {
        let directory = try scratch()
        let result = #"{"type":"user","uuid":"c","isSidechain":true,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t","content":"x"}]}}"#
        let lines = [agentTurn("a", cacheRead: 20_000), agentTurn("b", cacheRead: 41_000), result]
        try Data((lines.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        let context = try XCTUnwrap(SubagentTranscript.context(agentID: "a3c7e19b04f2d6a58", in: directory))
        XCTAssertEqual(context.tokens, 41_003)
        XCTAssertEqual(context.model, "claude-opus-5-5")
    }

    /// A tail that starts mid-record starts with half of one.
    func testATailDropsTheRecordItCutInto() {
        let whole = agentTurn("a", cacheRead: 20_000)
        let cut = String(whole.dropFirst(10))
        let tail = Data(cut.utf8)
        XCTAssertNil(SubagentTranscript.context(inTail: tail, isWholeFile: false))
        XCTAssertEqual(SubagentTranscript.context(inTail: Data(whole.utf8), isWholeFile: true)?.tokens, 20_003)
    }

    func testAnAgentThatHasNotTakenATurnCarriesNothingYet() throws {
        let directory = try scratch()
        XCTAssertNil(SubagentTranscript.context(agentID: "a3c7e19b04f2d6a58", in: directory))
        try Data(#"{"type":"user","uuid":"a","isSidechain":true,"message":{"role":"user","content":"go"}}"#.utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))
        XCTAssertNil(SubagentTranscript.context(agentID: "a3c7e19b04f2d6a58", in: directory))
    }

    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("subagents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}

final class LaunchedAgentIDTests: XCTestCase {

    /// The receipt as the CLI writes it, word for word.
    func testReadsTheIdOutOfALaunchReceipt() {
        let receipt = """
            Async agent launched successfully. (This tool result is internal metadata — never \
            quote or paste any part of it, including the agentId below, into a user-facing reply.)
            agentId: a3c7e19b04f2d6a58 (internal ID - do not mention to user. Use SendMessage \
            with to: 'a3c7e19b04f2d6a58', summary: '<5-10 word recap>' to continue this agent.)
            """
        XCTAssertEqual(TranscriptText.launchedAgentID(in: receipt), "a3c7e19b04f2d6a58")
    }

    /// Text that mentions an agent id without being a receipt — a transcript
    /// quoting one back, say — is not a launch.
    func testTextThatIsNotAReceiptNamesNothing() {
        XCTAssertNil(TranscriptText.launchedAgentID(in: "agentId: a3c7e19b04f2d6a58"))
        XCTAssertNil(TranscriptText.launchedAgentID(in: "Async agent launched successfully."))
        XCTAssertNil(TranscriptText.launchedAgentID(in: "file body"))
    }
}
