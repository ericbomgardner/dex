import XCTest
@testable import DexCore

/// Which model an agent ran on, read back off its own transcript. Pinned
/// against **CLI v2.1.243**. Both field names are load-bearing and neither is
/// documented: a rename reads as an agent that ran on nothing, and the row
/// simply goes back to the counts it drew before.
final class SubagentIdentityTests: XCTestCase {

    /// The two fields are in two places, which is the whole reason this can't
    /// be read off the message alone: `model` is inside `message`, `effort` is
    /// beside it at the top level.
    func testReadsTheModelAndEffortOffTheFirstAssistantTurn() throws {
        let identity = try XCTUnwrap(SubagentIdentity.read(lines: lines([
            #"{"type":"user","isSidechain":true,"message":{"content":"Review the diff"}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"medium","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#,
        ])))

        XCTAssertEqual(identity.model, "Sonnet 5")
        XCTAssertEqual(identity.effort, "medium")
        XCTAssertEqual(identity.summary, "Sonnet 5 · medium")
    }

    /// The placeholder the CLI writes on a turn it produced itself stands for
    /// no model, and it carries no effort either. Believed, it would put
    /// `<synthetic>` on the row of an agent that ran perfectly well — it was
    /// the *only* thing that varied within a file across a hundred-odd
    /// subagent transcripts.
    func testSkipsTheSyntheticPlaceholderAndKeepsLooking() throws {
        let identity = try XCTUnwrap(SubagentIdentity.read(lines: lines([
            #"{"type":"assistant","isSidechain":true,"message":{"model":"<synthetic>","content":[{"type":"text","text":"No response requested."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"xhigh","message":{"model":"claude-opus-5","content":[{"type":"text","text":"On it."}]}}"#,
        ])))

        XCTAssertEqual(identity.model, "Opus 5")
        XCTAssertEqual(identity.effort, "xhigh")
    }

    /// An agent that has been named but has not taken a turn names no model,
    /// and saying nothing is the right answer — the row draws its counts and
    /// no model term at all.
    func testAnAgentThatHasNotAnsweredYetNamesNothing() {
        XCTAssertNil(SubagentIdentity.read(lines: lines([
            #"{"type":"user","isSidechain":true,"message":{"content":"Review the diff"}}"#,
        ])))
        XCTAssertNil(SubagentIdentity.read(lines: []))
    }

    /// A turn naming a model but no effort is a model reading, not a discarded
    /// one. Nothing fills the gap in from the session: the floor the app sets
    /// is on the model, and an effort guessed from the parent would be the app
    /// reporting its own setting back to itself.
    func testAModelWithoutAnEffortStillReads() throws {
        let identity = try XCTUnwrap(SubagentIdentity.read(lines: lines([
            #"{"type":"assistant","isSidechain":true,"message":{"model":"claude-fable-5","content":[{"type":"text","text":"On it."}]}}"#,
        ])))

        XCTAssertEqual(identity.model, "Fable 5")
        XCTAssertNil(identity.effort)
        XCTAssertEqual(identity.summary, "Fable 5")
    }

    /// The window is a byte count, so the line it lands in the middle of is
    /// half a record. It has to be skipped rather than fail the read — and it
    /// is never the line being looked for, since a cut line is at the end of
    /// the window and the first turn naming a model is at the start.
    func testAHalfLineIsSkippedRatherThanBelieved() throws {
        let identity = try XCTUnwrap(SubagentIdentity.read(lines: lines([
            #"{"type":"assistant","isSidechain":true,"effort":"high","message":{"model":"claude-opus-5","content":[{"type":"text","text":"On it."}]}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"hi"#,
        ])))

        XCTAssertEqual(identity.model, "Opus 5")
        XCTAssertEqual(identity.effort, "high")
    }

    /// The whole chain off disk, in the shape the pane runs it: the file the
    /// agent wrote, read from the front, without opening the conversation.
    func testReadsAnAgentsModelOffTheHeadOfItsFile() throws {
        let directory = try scratch()
        var records = [
            #"{"type":"user","isSidechain":true,"message":{"content":"Review the diff"}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"medium","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#,
        ]
        // Past the window, so a read that got this far would be reading more of
        // the file than it is allowed to.
        let filler = String(repeating: "x", count: SubagentTranscript.identityWindow)
        records.append(
            #"{"type":"assistant","isSidechain":true,"effort":"low","message":{"model":"claude-haiku-4-5-20251001","content":[{"type":"text","text":"\#(filler)"}]}}"#
        )
        try Data((records.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        let identity = try XCTUnwrap(
            SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: directory)
        )
        XCTAssertEqual(identity.summary, "Sonnet 5 · medium")
    }

    /// Since CLI v2.1.266 an agent's file opens with its CLAUDE.md and memory
    /// as an `instructions` attachment — 190k in one sample, three times the
    /// chunk — before the agent has said a word. A read that stopped at one
    /// chunk named nothing for 42% of recent agents.
    func testAModelBehindTheInstructionsAttachmentStillReads() throws {
        let directory = try scratch()
        let instructions = String(repeating: "x", count: 3 * SubagentTranscript.identityWindow)
        let records = [
            #"{"type":"attachment","isSidechain":true,"attachment":{"type":"instructions","content":"\#(instructions)"}}"#,
            #"{"type":"attachment","isSidechain":true,"attachment":{"type":"prompt_snapshot","systemPrompt":["You are Claude Code."]}}"#,
            #"{"type":"user","isSidechain":true,"message":{"content":"Review the diff"}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"medium","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#,
        ]
        try Data((records.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        let identity = try XCTUnwrap(
            SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: directory)
        )
        XCTAssertEqual(identity.summary, "Sonnet 5 · medium")
    }

    /// The line that names the model can straddle two chunks, and a read that
    /// decoded each chunk on its own would see two halves and believe neither.
    func testAModelLineCutByTheChunkBoundaryStillReads() throws {
        let directory = try scratch()
        let frame = #"{"type":"user","isSidechain":true,"message":{"content":""}}"#
        let filler = String(
            repeating: "x",
            count: SubagentTranscript.identityWindow - 40 - frame.utf8.count - 1
        )
        let records = [
            #"{"type":"user","isSidechain":true,"message":{"content":"\#(filler)"}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"medium","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#,
        ]
        try Data((records.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        let identity = try XCTUnwrap(
            SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: directory)
        )
        XCTAssertEqual(identity.summary, "Sonnet 5 · medium")
    }

    /// A model named past the ceiling costs a line on a row, not a bigger read.
    func testAModelNamedPastTheCeilingReadsAsUnknown() throws {
        let directory = try scratch()
        let filler = String(repeating: "x", count: SubagentTranscript.identityCeiling)
        let records = [
            #"{"type":"user","isSidechain":true,"message":{"content":"\#(filler)"}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"medium","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#,
        ]
        try Data((records.joined(separator: "\n") + "\n").utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        XCTAssertNil(SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: directory))
    }

    /// A file whose last line has no newline behind it is finished, not
    /// half-written, and if that line is the first turn it still counts.
    func testAModelOnAnUnterminatedLastLineStillReads() throws {
        let directory = try scratch()
        let records = [
            #"{"type":"user","isSidechain":true,"message":{"content":"Review the diff"}}"#,
            #"{"type":"assistant","isSidechain":true,"effort":"low","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#,
        ]
        try Data(records.joined(separator: "\n").utf8)
            .write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        let identity = try XCTUnwrap(
            SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: directory)
        )
        XCTAssertEqual(identity.summary, "Sonnet 5 · low")
    }

    /// A file that ends exactly on the ceiling looks, from inside the scan,
    /// like one the ceiling cut. The read asks for one more byte to tell them
    /// apart, so the last line of a file that size still counts.
    func testAFileEndingExactlyOnTheCeilingStillReadsItsLastLine() throws {
        let directory = try scratch()
        let turn = #"{"type":"assistant","isSidechain":true,"effort":"high","message":{"model":"claude-sonnet-5","content":[{"type":"text","text":"On it."}]}}"#
        let frame = #"{"type":"user","isSidechain":true,"message":{"content":""}}"#
        let filler = String(
            repeating: "x",
            count: SubagentTranscript.identityCeiling - turn.utf8.count - 1 - frame.utf8.count
        )
        let file = #"{"type":"user","isSidechain":true,"message":{"content":"\#(filler)"}}"# + "\n" + turn
        let data = Data(file.utf8)
        XCTAssertEqual(data.count, SubagentTranscript.identityCeiling)
        try data.write(to: directory.appendingPathComponent("agent-a3c7e19b04f2d6a58.jsonl"))

        let identity = try XCTUnwrap(
            SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: directory)
        )
        XCTAssertEqual(identity.summary, "Sonnet 5 · high")
    }

    func testAnAgentWithNoFileNamesNothing() throws {
        XCTAssertNil(
            SubagentTranscript.identity(agentID: "a3c7e19b04f2d6a58", in: try scratch())
        )
    }

    private func lines(_ records: [String]) -> [Data] {
        records.map { Data($0.utf8) }
    }

    private func scratch() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("subagent-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }
}
