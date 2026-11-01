import XCTest
@testable import DexCore

final class TranscriptStandingTests: XCTestCase {

    private func owesTurn(_ lines: String...) -> Bool? {
        TranscriptStanding.owesTurn(in: lines.map { Data($0.utf8) })
    }

    private let reply = #"{"type":"assistant","uuid":"b","message":{"content":[{"type":"text","text":"done"}]}}"#
    private let call = #"{"type":"assistant","uuid":"c","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}"#
    private let result = #"{"type":"user","uuid":"d","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#
    private let prompt = #"{"type":"user","uuid":"e","message":{"content":"and the tests?"}}"#

    /// The reading this is all for: your message is in the file the moment you
    /// send it, half a minute before the CLI's own record of the session says the
    /// turn has started.
    func testAMessageWithNothingAfterItIsOwed() {
        XCTAssertEqual(owesTurn(reply, prompt), true)
    }

    func testAFinishedReplyOwesNothing() {
        XCTAssertEqual(owesTurn(prompt, reply), false)
    }

    /// A result is a record of its own, so a call at the end of the file is one
    /// nothing has come back to.
    func testACallWithNoResultIsOwed() {
        XCTAssertEqual(owesTurn(reply, call), true)
    }

    /// And the other half of a tool loop: the result is back and the model has
    /// the turn again.
    func testAResultWithNothingAfterItIsOwed() {
        XCTAssertEqual(owesTurn(call, result), true)
    }

    /// A turn that said something and asked for a tool in the same record is
    /// still going.
    func testATurnThatSpokeAndThenCalledIsOwed() {
        XCTAssertEqual(owesTurn(#"""
            {"type":"assistant","uuid":"c","message":{"content":[{"type":"text","text":"looking"},{"type":"tool_use","id":"t1","name":"Bash","input":{}}]}}
            """#), true)
    }

    /// A subagent's turns are its own conversation. The Task call that sent it
    /// out is on this one and is what says the work is still going.
    func testASubagentsOwnTurnsAreNotThisConversations() {
        let sidechain = #"{"type":"assistant","uuid":"s","isSidechain":true,"message":{"content":[{"type":"text","text":"on it"}]}}"#

        XCTAssertEqual(owesTurn(call, sidechain), true)
        XCTAssertEqual(owesTurn(reply, sidechain), false)
    }

    /// What the CLI feeds the model of its own accord is nobody's turn — and a
    /// session sitting on one of these after its last reply is finished, not
    /// working.
    func testWhatTheCLIFeedsItselfIsNotATurn() {
        let meta = #"{"type":"user","uuid":"m","isMeta":true,"message":{"content":"<skill>…</skill>"}}"#

        XCTAssertEqual(owesTurn(reply, meta), false)
    }

    /// The note that a turn was stopped is written as a user turn, which read as
    /// a message is a turn owed that nothing will ever answer — the row spins for
    /// as long as the session sits there. Both lines are the CLI's, off
    /// **v2.1.222**.
    func testTheNoteThatATurnWasStoppedEndsIt() {
        let stopped = #"{"type":"user","uuid":"i","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#
        let onACall = #"{"type":"user","uuid":"j","message":{"content":[{"type":"text","text":"[Request interrupted by user for tool use]"}]}}"#

        XCTAssertEqual(owesTurn(call, stopped), false)
        XCTAssertEqual(owesTurn(call, onACall), false)
    }

    /// And what is said after one is a turn like any other: stopping a session
    /// is how you get to say the next thing to it.
    func testAMessageAfterAStoppedTurnIsStillOwed() {
        let stopped = #"{"type":"user","uuid":"i","message":{"content":[{"type":"text","text":"[Request interrupted by user]"}]}}"#

        XCTAssertEqual(owesTurn(call, stopped, prompt), true)
    }

    /// Only the CLI's own note, and only where it is the whole of the record —
    /// quoting it back at the session is a message, and owed like one. The one
    /// that opens with the note matters most: a prefix test alone would read a
    /// pasted line with a question after it as the turn ending.
    func testQuotingTheNoteIsNotTheNote() {
        let quoted = #"{"type":"user","uuid":"k","message":{"content":[{"type":"text","text":"why did it say [Request interrupted by user]?"}]}}"#
        let opensWithIt = #"{"type":"user","uuid":"l","message":{"content":[{"type":"text","text":"[Request interrupted by user] — why did that happen?"}]}}"#
        let pastedAbove = #"{"type":"user","uuid":"m","message":{"content":[{"type":"text","text":"[Request interrupted by user]\nwhat stopped it?"}]}}"#

        XCTAssertEqual(owesTurn(reply, quoted), true)
        XCTAssertEqual(owesTurn(reply, opensWithIt), true)
        XCTAssertEqual(owesTurn(reply, pastedAbove), true)
    }

    /// Records the file carries that aren't turns at all — `mode`, `ai-title`,
    /// a summary — sit between the turns and say nothing about whose it is.
    func testRecordsThatArentTurnsAreReadPast() {
        XCTAssertEqual(
            owesTurn(prompt, #"{"type":"permission-mode","permissionMode":"plan"}"#),
            true
        )
    }

    /// A line still being written has no terminator and decodes to nothing. The
    /// record before it is the answer until it lands.
    func testAHalfWrittenLineIsReadPast() {
        XCTAssertEqual(
            owesTurn(prompt, #"{"type":"assistant","uuid":"f","message":{"conte"#),
            true
        )
    }

    /// Nothing whole to read is not an answer. Off disk it means look further
    /// back; there is nowhere further back than an empty file.
    func testNothingWholeIsNotAnAnswer() {
        XCTAssertNil(TranscriptStanding.owesTurn(in: []))
        XCTAssertNil(owesTurn(#"{"type":"assistant","uuid":"f","message":{"conte"#))
    }

    /// What a local command printed is written as a user turn, and nothing
    /// answers it — read at face value a session sitting on a finished
    /// `/compact` spins for as long as it sits there.
    func testWhatALocalCommandPrintedIsTheEndOfIt() {
        let command = #"{"type":"user","uuid":"c1","message":{"role":"user","content":"<command-name>/compact</command-name>\n            <command-message>compact</command-message>\n            <command-args></command-args>"}}"#
        let stdout = #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>Compacted </local-command-stdout>"}}"#
        let tui = #"{"type":"user","uuid":"c2","message":{"role":"user","content":"<local-command-stdout>[2mCompacted (ctrl+o to see full summary)[22m</local-command-stdout>"}}"#

        XCTAssertEqual(owesTurn(prompt, reply, command, stdout), false)
        XCTAssertEqual(owesTurn(prompt, reply, command, tui), false)
        XCTAssertEqual(
            owesTurn(reply, command), true,
            "a local command that hasn't printed yet is still pending"
        )
    }

    // Reading it off disk

    private func file(_ lines: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("standing-\(UUID().uuidString).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func padded(_ characters: Int) -> String {
        #"{"type":"user","uuid":"a","message":{"content":"\#(String(repeating: "x", count: characters))"}}"#
    }

    func testReadsTheEndOfAFile() throws {
        let url = try file([reply, prompt])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(TranscriptStanding.owesTurn(at: url))
    }

    /// The window opens mid-record on a long file, and half a record is not one —
    /// so the answer comes from what the window holds whole.
    func testAWindowThatOpensMidRecordDropsIt() throws {
        let url = try file([padded(4_000), reply])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(TranscriptStanding.owesTurn(at: url, windows: [2_000]))
    }

    /// A pasted log, or a tool result the size of a file read: one record can
    /// fill the window end to end, leaving nothing whole in it. Reading that as
    /// an empty file would take the spinner off the turn most likely to need it,
    /// so the window widens instead.
    func testARecordLongerThanTheWindowIsReachedByWidening() throws {
        let url = try file([reply, padded(8_000)])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(TranscriptStanding.owesTurn(at: url, windows: [2_000]),
                       "the narrow window alone holds no whole record")
        XCTAssertTrue(TranscriptStanding.owesTurn(at: url, windows: [2_000, 64_000]))
    }

    /// Past the last window it gives up rather than reading the file whole — a
    /// transcript runs to hundreds of megabytes, and the row keeps the answer the
    /// CLI's own record gave it.
    func testAWideningThatStillMissesOwesNothing() throws {
        let url = try file([reply, padded(8_000)])
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(TranscriptStanding.owesTurn(at: url, windows: [500, 2_000]))
    }

    func testAnEmptyFileOwesNothing() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("standing-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data().write(to: url)

        XCTAssertFalse(TranscriptStanding.owesTurn(at: url))
    }

    func testAFileThatIsntThereOwesNothing() {
        XCTAssertFalse(TranscriptStanding.owesTurn(
            at: URL(fileURLWithPath: "/nowhere/\(UUID().uuidString).jsonl")
        ))
    }
}

/// The reading joined onto the rows, which is the only place it does anything.
final class RowStandingTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("standing-rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("projects/-tmp"),
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ line: String, for name: String) throws {
        try (line + "\n").write(
            to: root.appendingPathComponent("projects/-tmp/uuid-\(name).jsonl"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func row(_ name: String, pid: Int?) -> SessionRowModel {
        let session = makeSession(name, state: .done, hostPID: pid)
        let url = TranscriptLocator(configDirectory: root).locate(sessionID: session.sessionId)
        let live = session.isLive
        return SessionRowModel(
            session: session,
            owesTurn: live && url.map { TranscriptStanding.owesTurn(at: $0) } == true
        )
    }

    func testALiveSessionOwesTheTurnItsTranscriptEndsOn() throws {
        try write(#"{"type":"user","uuid":"a","message":{"content":"go on"}}"#, for: "sent")

        let row = row("sent", pid: 4_242)
        XCTAssertTrue(row.owesTurn)
        XCTAssertTrue(row.isWorking)
    }

    /// A session with no process left is not working on the turn its file was cut
    /// off in the middle of.
    func testASessionWithNoProcessOwesNothing() throws {
        try write(#"{"type":"user","uuid":"a","message":{"content":"go on"}}"#, for: "gone")

        let row = row("gone", pid: nil)
        XCTAssertFalse(row.owesTurn)
        XCTAssertFalse(row.isWorking)
    }

    func testAFinishedTranscriptOwesNothing() throws {
        try write(
            #"{"type":"assistant","uuid":"b","message":{"content":[{"type":"text","text":"done"}]}}"#,
            for: "idle"
        )

        XCTAssertFalse(row("idle", pid: 4_242).owesTurn)
    }
}
