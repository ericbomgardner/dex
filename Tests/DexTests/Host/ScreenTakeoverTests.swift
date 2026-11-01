import Foundation
import Testing
@testable import DexCore

@Suite("Screen takeovers")
struct ScreenTakeoverTests {

    @Test("The host's kind decodes, and a stranger stays unknown")
    func kindDecodes() {
        #expect(HostAskKind(raw: "takeover") == .takeover)
        #expect(HostAskKind(raw: "takeover").raw == "takeover")
        #expect(HostAskKind(raw: "seizure") == .unknown("seizure"))
    }

    @Test("A takeover reads as a permission that says what it does to you")
    func readsAsPermission() {
        let ask = HostAsk(
            askId: "a1", key: "k1", kind: .takeover, toolName: "Bash",
            input: .object(["command": .string("DEX_DRIVES_SCREEN=1 /tmp/simclick click 2236 732")]),
            options: [
                HostAskOption(optionId: "allow_once", name: "Go ahead", kind: .allowOnce),
                HostAskOption(optionId: "redirect", name: "Not with my pointer", kind: .rejectOnce),
            ]
        )
        let request = HostAskContent.read(ask).permissionRequest
        #expect(request?.drivesScreen == true)
        #expect(request?.title == "Drive your screen")
        #expect(request?.summary?.contains("simclick") == true)

        let plain = HostAsk(
            askId: "a2", key: "k1", kind: .permission, toolName: "Bash",
            input: .object(["command": .string("ls")]), options: []
        )
        #expect(HostAskContent.read(plain).permissionRequest?.title == "Run a command")
    }

    @Test("The host says which line drives the screen, and an older host's silence reads as none")
    func drivingLineDecodes() throws {
        let said = """
        {"askId":"a3","key":"k1","kind":"takeover","toolName":"Bash",
         "input":{"command":"python3 - <<'EOF'\\nprint(1)\\nEOF\\nDEX_DRIVES_SCREEN=1 python3 ingest_export.py"},
         "options":[{"optionId":"allow_once","name":"Go ahead","kind":"allow_once"}],
         "screen":{"line":"DEX_DRIVES_SCREEN=1 python3 ingest_export.py","match":"DEX_DRIVES_SCREEN=1"}}
        """
        let ask = try JSONDecoder().decode(HostAsk.self, from: Data(said.utf8))
        #expect(ask.screen?.line == "DEX_DRIVES_SCREEN=1 python3 ingest_export.py")
        #expect(ask.screen?.match == "DEX_DRIVES_SCREEN=1")

        let unsaid = """
        {"askId":"a4","key":"k1","kind":"takeover","toolName":"Bash",
         "input":{"command":"cliclick c:1,2"},"options":[]}
        """
        #expect(try JSONDecoder().decode(HostAsk.self, from: Data(unsaid.utf8)).screen == nil)
    }

    @Test("The bar names the driving line, not the first line of a script that ends in one")
    func barNamesTheDrivingLine() {
        let script = "python3 - <<'EOF'\nprint(1)\nEOF\nDEX_DRIVES_SCREEN=1 python3 ingest_export.py"
        let drive = HostScreenDrive(line: "DEX_DRIVES_SCREEN=1 python3 ingest_export.py", match: "DEX_DRIVES_SCREEN=1")
        let ask = HostAsk(
            askId: "a5", key: "k1", kind: .takeover, toolName: "Bash",
            input: .object(["command": .string(script)]), options: [], screen: drive
        )
        let request = HostAskContent.read(ask).permissionRequest
        #expect(request?.screen == drive)
        #expect(request?.drivingLine == "DEX_DRIVES_SCREEN=1 python3 ingest_export.py")

        let older = HostAsk(
            askId: "a6", key: "k1", kind: .takeover, toolName: "Bash",
            input: .object(["command": .string(script)]), options: []
        )
        #expect(HostAskContent.read(older).permissionRequest?.drivingLine?.hasPrefix("python3 - <<'EOF'") == true)
    }

    @Test("Away from the keyboard the session gets the screen; at it, you are asked")
    func idleDecides() {
        #expect(ScreenTakeoverPolicy.decide(idleFor: 31, alreadyDriving: false) == .allow)
        #expect(ScreenTakeoverPolicy.decide(idleFor: 30, alreadyDriving: false) == .allow)
        #expect(ScreenTakeoverPolicy.decide(idleFor: 2, alreadyDriving: false) == .ask)
        #expect(ScreenTakeoverPolicy.decide(idleFor: 0, alreadyDriving: false) == .ask)
    }

    @Test("Once let through, the rest of the turn is not asked again")
    func turnHoldsTheGrant() {
        #expect(ScreenTakeoverPolicy.decide(idleFor: 0, alreadyDriving: true) == .allow)
    }

    @Test("The turn ending takes the bar down; anything else leaves it up")
    func endsWithTheTurn() {
        #expect(ScreenTakeoverPolicy.endsTakeover(.idle))
        #expect(ScreenTakeoverPolicy.endsTakeover(.done))
        #expect(ScreenTakeoverPolicy.endsTakeover(.failed))
        #expect(!ScreenTakeoverPolicy.endsTakeover(.running))
        #expect(!ScreenTakeoverPolicy.endsTakeover(.asking))
        #expect(!ScreenTakeoverPolicy.endsTakeover(.starting))
        #expect(!ScreenTakeoverPolicy.endsTakeover(.unknown("paused")))
    }

    @Test("A drive still running past its turn keeps the bar up until the session ends")
    func outlivesTheTurn() {
        #expect(!ScreenTakeoverPolicy.endsTakeover(.idle, driveStillRunning: true))
        #expect(ScreenTakeoverPolicy.endsTakeover(.done, driveStillRunning: true))
        #expect(ScreenTakeoverPolicy.endsTakeover(.failed, driveStillRunning: true))
    }

    @Test("The notice names the session and what it is doing")
    func draftNamesTheSession() {
        let row = SessionRowModel(
            session: AgentSession(
                cwd: "/Users/me/Projects/garden",
                startedAt: 1_753_000_000_000, hostKey: "k1",
                state: .running, sessionId: "sess-1", name: "Native app iOS icon"
            ),
            hostedSummary: nil
        )
        let draft = SessionTransitions.takeoverDraft(for: row, doing: "/tmp/simclick click 2236 732")
        #expect(draft.title == "Driving your screen: Native app iOS icon")
        #expect(draft.body == "/tmp/simclick click 2236 732")
        #expect(draft.key == "k1")
        #expect(!draft.needsInput)
    }
}

@Suite("Screen takeover lapse")
struct ScreenTakeoverLapseTests {
    let drove = Date(timeIntervalSince1970: 1_000)
    var takeover: ScreenTakeover {
        ScreenTakeover(key: "k", since: drove, lastDrove: drove, command: "drive click 1 2", doing: nil)
    }

    @Test("A session that drove, came back and moved on lets go of the screen")
    func lapsesAfterTheCommandCameBack() {
        let back = drove + 3
        #expect(ScreenTakeoverPolicy.hasLapsed(
            takeover, returnedAt: back, stillRunning: false, now: back + ScreenTakeoverPolicy.lapseAfter
        ))
        #expect(!ScreenTakeoverPolicy.hasLapsed(
            takeover, returnedAt: back, stillRunning: false, now: back + ScreenTakeoverPolicy.lapseAfter - 1
        ))
    }

    @Test("A drive with no result yet holds the screen however long it takes")
    func holdsWhileTheCommandRuns() {
        #expect(!ScreenTakeoverPolicy.hasLapsed(takeover, returnedAt: nil, stillRunning: false, now: drove + 600))
    }

    @Test("A backgrounded drive has a result and is still clicking")
    func holdsWhileBackgrounded() {
        #expect(!ScreenTakeoverPolicy.hasLapsed(takeover, returnedAt: drove + 1, stillRunning: true, now: drove + 600))
    }

    @Test("An earlier run of the same command is not this drive coming back")
    func ignoresAnEarlierRun() {
        #expect(!ScreenTakeoverPolicy.hasLapsed(takeover, returnedAt: drove - 5, stillRunning: false, now: drove + 600))
    }

    @Test("A drive is found by its command, newest call first, with when it came back")
    func findsTheDriveByCommand() throws {
        func line(_ json: String) -> Data { Data(json.utf8) }
        var returns = DriveReturns()
        returns.read([
            line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"drive click 1 2"}}]}}"#),
            line(#"{"type":"user","timestamp":"2026-09-24T02:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#),
            line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"drive click 1 2"}}]}}"#),
        ])
        let drive = try #require(returns.call(running: "drive click 1 2"))
        #expect(drive.id == "t2")
        #expect(drive.returnedAt == nil)

        returns.read([
            line(#"{"type":"user","timestamp":"2026-09-24T02:00:09.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"ok"}]}}"#),
        ])
        #expect(returns.call(running: "drive click 1 2")?.returnedAt != nil)
        #expect(returns.call(running: "ls") == nil)
    }

    @Test("A drive that keeps watching is found by its Monitor call, and holds while the watch runs")
    func findsAWatchingDrive() throws {
        func line(_ json: String) -> Data { Data(json.utf8) }
        var returns = DriveReturns()
        returns.read([
            line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"m1","name":"Monitor","input":{"command":"DEX_DRIVES_SCREEN=1 drive watch","description":"watch"}}]}}"#),
            line(#"{"type":"user","timestamp":"2026-09-24T02:00:00.000Z","message":{"content":[{"type":"tool_result","tool_use_id":"m1","content":"started"}]}}"#),
            line(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"r1","name":"Read","input":{"command":"DEX_DRIVES_SCREEN=1 drive watch"}}]}}"#),
        ])
        let drive = try #require(returns.call(running: "DEX_DRIVES_SCREEN=1 drive watch"))
        #expect(drive.id == "m1")
        let back = try #require(drive.returnedAt)
        let takeover = ScreenTakeover(key: "k", since: back - 1, lastDrove: back - 1, command: drive.id, doing: nil)
        #expect(!ScreenTakeoverPolicy.hasLapsed(takeover, returnedAt: back, stillRunning: true, now: back + 600))
    }
}
