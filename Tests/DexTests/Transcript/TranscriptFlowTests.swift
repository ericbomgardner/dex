import XCTest
@testable import DexCore

final class TranscriptFlowTests: XCTestCase {

    private var nextID = 0

    private func id() -> String {
        nextID += 1
        return "b\(nextID)"
    }

    private func tool(
        _ name: String,
        result: ToolResult? = ToolResult(text: "ok", isError: false)
    ) -> TranscriptBlock {
        .toolCall(ToolCall(id: id(), name: name, input: .object([:]), result: result))
    }

    /// A call the transcript has recorded with no result yet.
    private func pending(_ name: String) -> TranscriptBlock {
        tool(name, result: nil)
    }

    private func question(_ asked: String, answer: String? = nil) -> TranscriptBlock {
        let input = JSONValue.object(["questions": .array([.object(["question": .string(asked)])])])
        let reply = answer.map { ToolResult(text: "\"\(asked)\"=\"\($0)\"", isError: false) }
        return .toolCall(ToolCall(id: id(), name: "AskUserQuestion", input: input, result: reply))
    }

    private func plan(_ body: String, result: ToolResult? = nil) -> TranscriptBlock {
        .toolCall(
            ToolCall(
                id: id(),
                name: "ExitPlanMode",
                input: .object(["plan": .string(body)]),
                result: result
            )
        )
    }

    private func proposal(_ item: TranscriptItem?) -> PlanProposal? {
        guard case .plan(let proposal) = item else { return nil }
        return proposal
    }

    private func text(_ value: String) -> TranscriptBlock {
        .prose(TranscriptProse(id: id(), text: value))
    }

    private func entry(_ role: TranscriptRole, _ blocks: TranscriptBlock...) -> TranscriptEntry {
        TranscriptEntry(id: id(), role: role, at: nil, blocks: blocks)
    }

    private func run(_ item: TranscriptItem?) -> TranscriptToolRun? {
        guard case .toolRun(let run) = item else { return nil }
        return run
    }

    private func active(_ item: TranscriptItem?) -> ToolCall? {
        guard case .activeTool(let call) = item else { return nil }
        return call
    }

    private func reply(_ item: TranscriptItem?) -> TranscriptReply? {
        guard case .reply(let reply) = item else { return nil }
        return reply
    }

    private func received(_ from: String?, _ body: String) -> TranscriptBlock {
        .peer(PeerMessage(id: id(), direction: .inbound, name: from, body: body))
    }

    private func peer(_ item: TranscriptItem?) -> PeerMessage? {
        guard case .peer(let message) = item else { return nil }
        return message
    }

    private func sent(_ to: String, _ message: String, result: ToolResult? = ToolResult(text: "{\"success\":true}", isError: false)) -> TranscriptBlock {
        .toolCall(
            ToolCall(
                id: id(),
                name: "SendMessage",
                input: .object(["to": .string(to), "summary": .string("s"), "message": .string(message)]),
                result: result
            )
        )
    }

    // Grouping

    func testToolCallsInOneTurnBecomeOneRun() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Bash"), tool("Read"), tool("Grep"))
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(run(items.first)?.calls.count, 3)
    }

    func testARunKeepsGoingAcrossTurns() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Bash")),
            entry(.assistant, tool("Bash")),
            entry(.assistant, tool("Read")),
        ])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(run(items.first)?.calls.count, 3)
    }

    func testSomethingSaidEndsTheRun() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Bash")),
            entry(.assistant, text("here is what I found"), tool("Read")),
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(run(items.first)?.calls.count, 1)
        XCTAssertNotNil(reply(items[1]))
        XCTAssertEqual(run(items.last)?.calls.count, 1)
    }

    func testALoneCallIsARunOfOne() {
        let items = TranscriptFlow.items(from: [entry(.assistant, tool("Bash"))])
        XCTAssertEqual(run(items.first)?.isSingle, true)
    }

    func testAQuestionStandsOnItsOwn() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Bash"), question("Which one?"), tool("Read"))
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(run(items.first)?.calls.count, 1)
        guard case .question(let call) = items[1] else { return XCTFail("expected a question") }
        XCTAssertEqual(call.askedQuestions.first?.question, "Which one?")
        XCTAssertEqual(run(items.last)?.calls.count, 1)
    }

    func testASubagentStandsOnItsOwn() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), tool("Task"), tool("Grep"))
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(run(items[0])?.names, ["Read"])
        XCTAssertEqual(run(items[1])?.names, ["Task"])
        XCTAssertEqual(run(items[2])?.names, ["Grep"])
    }

    func testAFanOutIsOneRowPerAgent() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Task"), tool("Task"), tool("Agent"))
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertTrue(items.allSatisfy { run($0)?.isSingle == true })
    }

    /// A background agent works on while the conversation carries on past it, so
    /// where it sits says nothing about whether it is still going.
    func testAnAgentStillOutIsRunningWhereverItSits() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Task")),
            entry(.assistant, text("while that runs, I'll read the other file")),
            entry(.assistant, tool("Read")),
        ])
        XCTAssertEqual(TranscriptFlow.running(in: items).map(\.name), ["Task"])
    }

    func testTheAgentThatCameBackFirstDoesNotStopTheOthersClocks() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Task"), tool("Task"), pending("Task"))
        ])
        XCTAssertEqual(TranscriptFlow.running(in: items).count, 2)
        XCTAssertEqual(items.count, 3)
    }

    // The agents alone, for the row over the composer

    func testTheAgentsAreToldFromTheCallsAroundThem() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Task")),
            entry(.assistant, pending("Bash")),
        ])
        XCTAssertEqual(TranscriptFlow.agents(in: items).map(\.name), ["Task"])
    }

    func testTheAgentsComeBackOldestFirst() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Task")),
            entry(.assistant, pending("Agent")),
        ])
        XCTAssertEqual(TranscriptFlow.agents(in: items).map(\.name), ["Task", "Agent"])
    }

    func testAnAgentThatCameBackIsNotOut() {
        let items = TranscriptFlow.items(from: [entry(.assistant, tool("Task"))])
        XCTAssertTrue(TranscriptFlow.agents(in: items).isEmpty)
    }

    /// Sent out in the same breath as the agent, so it is running beside it —
    /// folded into the collapsed run above, it would leave the strip saying the
    /// session was waiting on agents while a build was going.
    func testACallMadeBesideAnAgentIsStillRunning() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Bash"), pending("Task"))
        ])
        XCTAssertEqual(TranscriptFlow.running(in: items).map(\.name), ["Bash", "Task"])
        XCTAssertFalse(TranscriptFlow.isWaitingOnAgents(in: items))
    }

    /// Calls made together come back in whatever order they finish, so a slow
    /// one has settled ones sitting after it in the run. Told apart by where
    /// they sit rather than by what has come back, the slow one is buried in
    /// the stretch the quick one closed.
    func testAQuickCallComingBackFirstDoesNotBuryTheSlowOne() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Bash"), tool("Read"), pending("Task"))
        ])
        XCTAssertEqual(TranscriptFlow.running(in: items).map(\.name), ["Bash", "Task"])
        XCTAssertFalse(TranscriptFlow.isWaitingOnAgents(in: items))
    }

    /// The turn is read in the order it happened, so a call still running stays
    /// where it was made — gathered at the end, a read that has already come
    /// back would sit above a build that was started before it.
    func testACallStillRunningKeepsItsPlaceInTheTurn() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), pending("Bash"), tool("Grep"), pending("Task"))
        ])
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(run(items[0])?.names, ["Read"])
        XCTAssertEqual(active(items[1])?.name, "Bash")
        XCTAssertEqual(run(items[2])?.names, ["Grep"])
        XCTAssertEqual(active(items[3])?.name, "Task")
    }

    /// The other half of that rule: something *said* after a call means the
    /// conversation carried on without it.
    func testACallLeftBehindBeforeAnAgentIsStillAbandoned() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Bash")),
            entry(.assistant, text("that never came back — sending an agent instead")),
            entry(.assistant, pending("Task")),
        ])
        XCTAssertEqual(TranscriptFlow.running(in: items).map(\.name), ["Task"])
        XCTAssertTrue(TranscriptFlow.isWaitingOnAgents(in: items))
    }

    /// Nothing of the session's own is running, so the row over the composer is
    /// the agents' and not a claim that the session is working too.
    func testEverythingInFlightBeingAnAgentIsWaiting() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Task")),
            entry(.assistant, pending("Agent")),
        ])
        XCTAssertTrue(TranscriptFlow.isWaitingOnAgents(in: items))
    }

    func testACallOfItsOwnMeansItIsNotJustWaiting() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Task")),
            entry(.assistant, pending("Bash")),
        ])
        XCTAssertFalse(TranscriptFlow.isWaitingOnAgents(in: items))
    }

    /// A session between calls is thinking, which is work of its own.
    func testNothingRunningIsNotWaiting() {
        let items = TranscriptFlow.items(from: [entry(.assistant, tool("Bash"))])
        XCTAssertFalse(TranscriptFlow.isWaitingOnAgents(in: items))
    }

    // What the collapsed line says

    func testARunNamesEachToolOnceInTheOrderItRan() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Bash"), tool("Bash"), tool("Read"), tool("Bash"))
        ])
        XCTAssertEqual(run(items.first)?.names, ["Bash", "Read"])
    }

    /// A call a resume answered with "outcome unknown" never came back.
    func testAnUnrecordedOutcomeReadsAsNeverCameBack() {
        let unrecorded = ToolResult(
            text: "[Tool call interrupted: the session ended before this call's result was recorded, so its outcome is unknown.]",
            isError: true
        )
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Agent", result: unrecorded), tool("Read")),
            entry(.assistant, text("No response requested.")),
        ])
        XCTAssertEqual(run(items.first)?.isPending, true)
    }

    /// A call the conversation carried on past stays in the run it was made in,
    /// which is the one way a finished stretch still holds something that never
    /// came back. A call still running doesn't: it stands on its own.
    func testARunIsPendingWhileAnyCallItKeptIs() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Bash"), tool("Read")),
            entry(.assistant, text("that one never came back — moving on")),
        ])
        XCTAssertEqual(run(items.first)?.calls.count, 2)
        XCTAssertEqual(run(items.first)?.isPending, true)
    }

    // What is running right now

    func testTheCallStillWaitingIsLeftOutOfTheCollapsedRun() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), tool("Grep"), pending("Bash"))
        ])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(run(items.first)?.calls.count, 2)
        XCTAssertEqual(TranscriptFlow.running(in: items).map(\.name), ["Bash"])
    }

    func testEveryCallStillWaitingStandsOnItsOwn() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Bash"), pending("Read"))
        ])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(TranscriptFlow.running(in: items).map(\.name), ["Bash", "Read"])
    }

    func testACallLeftBehindMidConversationIsNotRunning() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, pending("Bash")),
            entry(.assistant, text("that never came back — moving on")),
        ])
        XCTAssertTrue(TranscriptFlow.running(in: items).isEmpty)
        XCTAssertEqual(run(items.first)?.calls.count, 1)
    }

    func testNothingIsRunningOnceEveryCallHasComeBack() {
        let items = TranscriptFlow.items(from: [entry(.assistant, tool("Bash"), tool("Read"))])
        XCTAssertTrue(TranscriptFlow.running(in: items).isEmpty)
        XCTAssertEqual(run(items.first)?.calls.count, 2)
    }

    // Prose

    func testWhatYouTypedStaysAPrompt() {
        let items = TranscriptFlow.items(from: [entry(.user, text("# not a heading"))])
        guard case .prompt(let prose) = items.first else { return XCTFail("expected a prompt") }
        XCTAssertEqual(prose.text, "# not a heading")
    }

    func testARepliesMarkdownIsParsed() {
        let items = TranscriptFlow.items(from: [entry(.assistant, text("## Plan\n\n- one\n- two"))])
        XCTAssertEqual(reply(items.first)?.blocks.count, 2)
        XCTAssertEqual(reply(items.first)?.blocks.first, .heading(level: 2, text: "Plan"))
    }

    func testThinkingIsItsOwnItem() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, .thinking(TranscriptProse(id: id(), text: "hmm")), tool("Bash"))
        ])
        XCTAssertEqual(items.count, 2)
        guard case .thinking = items.first else { return XCTFail("expected thinking") }
    }

    // Text too long to lay out

    private func overLong(by extra: Int) -> String {
        String(repeating: "a", count: TranscriptFlow.proseLimit + extra)
    }

    func testAPromptTooLongToLayOutIsClipped() {
        let items = TranscriptFlow.items(from: [entry(.user, text(overLong(by: 500)))])
        guard case .prompt(let prose) = items.first else { return XCTFail("expected a prompt") }
        XCTAssertTrue(prose.text.hasSuffix("… 500 more characters"))
    }

    func testAPromptThatFitsKeepsEveryCharacter() {
        let typed = String(repeating: "a", count: TranscriptFlow.proseLimit)
        let items = TranscriptFlow.items(from: [entry(.user, text(typed))])
        guard case .prompt(let prose) = items.first else { return XCTFail("expected a prompt") }
        XCTAssertEqual(prose.text, typed)
    }

    func testAThoughtTooLongToLayOutIsClipped() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, .thinking(TranscriptProse(id: id(), text: overLong(by: 12))))
        ])
        guard case .thinking(let prose) = items.first else { return XCTFail("expected thinking") }
        XCTAssertTrue(prose.text.hasSuffix("… 12 more characters"))
    }

    /// The parser runs on the clipped text, so no one block can be enormous
    /// either — a reply that is one long fenced block included.
    func testALongReplyIsClippedBeforeItsMarkdownIsParsed() {
        let long = Array(repeating: "a paragraph of reply", count: 4_000).joined(separator: "\n\n")
        let items = TranscriptFlow.items(from: [entry(.assistant, text(long))])
        let blocks = reply(items.first)?.blocks ?? []
        let laidOut = blocks.reduce(0) { total, block in
            guard case .paragraph(let text) = block else { return total }
            return total + text.count
        }
        XCTAssertLessThanOrEqual(laidOut, TranscriptFlow.proseLimit)
        guard case .paragraph(let last) = blocks.last else { return XCTFail("expected a paragraph") }
        XCTAssertTrue(last.hasSuffix("more characters"))
    }

    // The plan put up for approval

    /// Folded into the run around it, the thing the whole turn was for reads as
    /// "4 tool calls".
    func testAPlanStandsOnItsOwn() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), plan("# Do it\n\nFirst, the thing."), tool("Bash")),
        ])
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(run(items[0])?.calls.count, 1)
        XCTAssertEqual(proposal(items[1])?.blocks.first, .heading(level: 1, text: "Do it"))
        XCTAssertEqual(run(items[2])?.calls.count, 1)
    }

    func testAPlanStillWaitingIsShownRatherThanHeldBack() {
        let items = TranscriptFlow.items(from: [entry(.assistant, plan("# Do it"))])
        XCTAssertEqual(proposal(items.first)?.outcome, .waiting)
        XCTAssertTrue(TranscriptFlow.running(in: items).isEmpty,
                      "it is waiting on an answer, not working")
    }

    func testAnApprovedPlanSaysSo() {
        let approved = ToolResult(text: "User has approved your plan.", isError: false)
        let items = TranscriptFlow.items(from: [entry(.assistant, plan("# Do it", result: approved))])
        XCTAssertEqual(proposal(items.first)?.outcome, .approved(edited: false))
    }

    func testAPlanRewrittenInTheDialogSaysSo() {
        let edited = ToolResult(text: "User has approved your plan.", isError: false, planWasEdited: true)
        let items = TranscriptFlow.items(from: [entry(.assistant, plan("# Do it", result: edited))])
        XCTAssertEqual(proposal(items.first)?.outcome, .approved(edited: true))
    }

    func testARejectedPlanCarriesWhatTheUserSaid() {
        let refused = ToolResult(
            text: "The user doesn't want to proceed with this tool use. The tool use was "
                + "rejected. To tell you how to proceed, the user said:\nuse a sheet instead",
            isError: true
        )
        let items = TranscriptFlow.items(from: [entry(.assistant, plan("# Do it", result: refused))])
        XCTAssertEqual(proposal(items.first)?.outcome, .rejected(reason: "use a sheet instead"))
    }

    func testARejectedPlanWithNothingSaidCarriesNoReason() {
        let refused = ToolResult(text: "The user doesn't want to proceed with this tool use.", isError: true)
        let items = TranscriptFlow.items(from: [entry(.assistant, plan("# Do it", result: refused))])
        XCTAssertEqual(proposal(items.first)?.outcome, .rejected(reason: nil))
    }

    /// Nothing to read means nothing to make a card of, so it goes back to being
    /// an ordinary call rather than an empty box.
    func testAPlanWithNoBodyIsJustACall() {
        let bare = TranscriptBlock.toolCall(
            ToolCall(
                id: id(),
                name: "ExitPlanMode",
                input: .object([:]),
                result: ToolResult(text: "ok", isError: false)
            )
        )
        let items = TranscriptFlow.items(from: [entry(.assistant, bare)])
        XCTAssertNil(proposal(items.first))
        XCTAssertEqual(run(items.first)?.calls.first?.name, "ExitPlanMode")
    }

    func testEveryItemHasItsOwnIdentity() {
        let items = TranscriptFlow.items(from: [
            entry(.user, text("go")),
            entry(.assistant, text("ok"), tool("Bash")),
            entry(.assistant, tool("Read")),
        ])
        XCTAssertEqual(Set(items.map(\.id)).count, items.count)
    }

    // Work the host says is still going

    /// A backgrounded command answers with its launch receipt, so the file has
    /// it as a call that finished and then says nothing for as long as it runs.
    func testHostsRunningCallStandsOutOfTheRunItWasFoldedInto() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), tool("Bash"), tool("Grep"))
        ])
        let backgrounded = run(items.first)?.calls[1].id
        XCTAssertNotNil(backgrounded)

        let marked = TranscriptFlow.marking(items, running: [backgrounded!])

        XCTAssertEqual(marked.count, 3)
        XCTAssertEqual(run(marked.first)?.calls.map(\.name), ["Read"])
        XCTAssertEqual(active(marked[1])?.name, "Bash")
        XCTAssertEqual(run(marked[2])?.calls.map(\.name), ["Grep"])
    }

    func testMarkingNamesTheCallAsBackgroundWorkRatherThanAsAnAgent() {
        let items = TranscriptFlow.items(from: [entry(.assistant, tool("Bash"))])
        let marked = TranscriptFlow.marking(items, running: [run(items.first)!.calls[0].id])

        XCTAssertEqual(TranscriptFlow.backgroundWork(in: marked).map(\.name), ["Bash"])
        XCTAssertTrue(TranscriptFlow.agents(in: marked).isEmpty)
    }

    /// The common case, and the one that has to cost nothing: a session with no
    /// task out reads exactly as it did before.
    func testNothingRunningLeavesTheItemsAlone() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), tool("Bash"))
        ])
        XCTAssertEqual(TranscriptFlow.marking(items, running: []).map(\.id), items.map(\.id))
    }

    /// Transcripts get read back into sessions, so an id that names no call in
    /// this one has to land on nothing.
    func testARunningIdThatNamesNoCallChangesNothing() {
        let items = TranscriptFlow.items(from: [entry(.assistant, tool("Bash"))])
        XCTAssertEqual(
            TranscriptFlow.marking(items, running: ["nobody"]).map(\.id),
            items.map(\.id)
        )
    }

    /// The call the session is in the middle of is the session working, which
    /// the strip already has a line for. Counting it here would name it twice.
    func testTheSessionsOwnCallInFlightIsNotBackgroundWork() {
        let items = TranscriptFlow.items(from: [entry(.assistant, pending("Bash"))])
        XCTAssertEqual(active(items.first)?.name, "Bash")
        XCTAssertTrue(TranscriptFlow.backgroundWork(in: items).isEmpty)
    }

    func testAnAgentStillOutIsNotBackgroundWork() {
        let items = TranscriptFlow.items(from: [entry(.assistant, pending("Task"))])
        XCTAssertEqual(TranscriptFlow.agents(in: items).map(\.name), ["Task"])
        XCTAssertTrue(TranscriptFlow.backgroundWork(in: items).isEmpty)
    }

    /// A resumed agent's task is filed under the SendMessage that woke it, so
    /// the host has no task under the agent's own call.
    func testAResumedAgentIsFoundByTheIdItsFirstRunCameBackWith() {
        let agent = ToolCall(
            id: id(), name: "Agent", input: .object([:]),
            result: ToolResult(text: "done", isError: false), agentID: "a6d7"
        )
        let send = ToolCall(
            id: id(), name: "SendMessage", input: .object(["to": .string("a6d7"), "message": .string("go on")]),
            result: ToolResult(text: "sent", isError: false)
        )
        let items = TranscriptFlow.items(from: [
            entry(.assistant, .toolCall(agent)),
            entry(.assistant, .toolCall(send)),
        ])
        XCTAssertTrue(TranscriptFlow.agents(in: items).isEmpty)

        let marked = TranscriptFlow.marking(items, running: [send.id], agents: [send.id: "a6d7"])

        XCTAssertEqual(TranscriptFlow.agents(in: marked).map(\.id), [agent.id])
        XCTAssertTrue(TranscriptFlow.backgroundWork(in: marked).isEmpty)
    }

    /// Counted from its first launch, the clock would include every hour the
    /// agent sat finished before the message woke it.
    func testAResumedAgentsClockRunsFromTheMessageThatWokeIt() {
        let launched = Date(timeIntervalSince1970: 1_000_000)
        let woken = launched.addingTimeInterval(7_200)
        let agent = ToolCall(
            id: id(), name: "Agent", input: .object([:]), startedAt: launched,
            finishedAt: launched.addingTimeInterval(60),
            result: ToolResult(text: "done", isError: false), agentID: "a6d7"
        )
        let send = ToolCall(
            id: id(), name: "SendMessage", input: .object(["to": .string("a6d7"), "message": .string("go on")]),
            startedAt: woken, result: ToolResult(text: "sent", isError: false)
        )
        let items = TranscriptFlow.items(from: [
            TranscriptEntry(id: id(), role: .assistant, at: launched, blocks: [.toolCall(agent)]),
            TranscriptEntry(id: id(), role: .assistant, at: woken, blocks: [.toolCall(send)]),
        ])

        let resumed = TranscriptFlow.marking(items, running: [send.id], agents: [send.id: "a6d7"])
        XCTAssertEqual(TranscriptFlow.agents(in: resumed).map(\.startedAt), [woken])

        let fresh = TranscriptFlow.marking(items, running: [agent.id], agents: [agent.id: "a6d7"])
        XCTAssertEqual(TranscriptFlow.agents(in: fresh).map(\.startedAt), [launched])
    }

    /// No clock beats one counting from the first launch.
    func testAResumedAgentWhoseWakeIsNotReadHasNoClock() {
        let agent = ToolCall(
            id: id(), name: "Agent", input: .object([:]), startedAt: Date(timeIntervalSince1970: 1_000_000),
            result: ToolResult(text: "done", isError: false), agentID: "a6d7"
        )
        let items = TranscriptFlow.items(from: [entry(.assistant, .toolCall(agent))])

        let marked = TranscriptFlow.marking(items, running: ["unread"], agents: ["unread": "a6d7"])
        XCTAssertEqual(TranscriptFlow.agents(in: marked).map(\.id), [agent.id])
        XCTAssertNil(TranscriptFlow.agents(in: marked).first?.startedAt)
    }

    func testAnAgentIdOnlyMarksAnAgent() {
        let bash = ToolCall(
            id: id(), name: "Bash", input: .object([:]),
            result: ToolResult(text: "ok", isError: false), agentID: "a6d7"
        )
        let items = TranscriptFlow.items(from: [entry(.assistant, .toolCall(bash))])
        XCTAssertEqual(
            TranscriptFlow.marking(items, running: [], agents: ["b0": "a6d7"]).map(\.id),
            items.map(\.id)
        )
    }

    func testMarkedItemsKeepTheirOwnIdentities() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), tool("Bash"), tool("Grep"))
        ])
        let marked = TranscriptFlow.marking(items, running: [run(items.first)!.calls[1].id])
        XCTAssertEqual(Set(marked.map(\.id)).count, marked.count)
    }

    /// Why the pane's two "is it working" readings are taken off the file and
    /// only the strip's extra rows off the host: marked, a command the session
    /// walked away from counts as work in flight, and it outlives the turn that
    /// started it. Read that way, one long command tells the pane there is
    /// nothing to say for every turn it runs through.
    func testMarkingCountsAsWorkInFlightWhichIsWhyItIsAskedForSeparately() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Bash")),
            entry(.assistant, pending("Task")),
        ])
        let backgrounded = run(items.first)!.calls[0].id

        XCTAssertTrue(TranscriptFlow.isWaitingOnAgents(in: items))
        XCTAssertEqual(TranscriptFlow.running(in: items).count, 1)

        let marked = TranscriptFlow.marking(items, running: [backgrounded])

        XCTAssertFalse(TranscriptFlow.isWaitingOnAgents(in: marked))
        XCTAssertEqual(TranscriptFlow.running(in: marked).count, 2)
    }

    // Side conversations

    /// A message from another session is neither side of this conversation.
    /// Drawn as a prompt it reads as something you typed, so it is its own
    /// item, carrying the sender's name and the body apart — and a prompt
    /// typed to look like one stays a prompt, since the block says which.
    func testAMessageFromAnotherSessionIsAPeerItemNotAPrompt() {
        let items = TranscriptFlow.items(from: [
            entry(.user, received("kestrel-9d", "are those yours?")),
            entry(.user, received(nil, "anonymous")),
            entry(.user, text(TranscriptText.peerMessage(from: "kestrel-9d", body: "typed here"))),
        ])

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(peer(items[0])?.direction, .inbound)
        XCTAssertEqual(peer(items[0])?.name, "kestrel-9d")
        XCTAssertEqual(peer(items[0])?.body, "are those yours?")
        XCTAssertEqual(peer(items[1])?.direction, .inbound)
        XCTAssertNil(peer(items[1])?.name)
        XCTAssertEqual(peer(items[1])?.body, "anonymous")
        XCTAssertNil(peer(items[2]))
        if case .prompt = items[2] {} else { XCTFail("a typed line is a prompt") }
    }

    /// The session's reply goes out as a `SendMessage` call, and folded into
    /// "2 tool calls" it is a side of the exchange nobody can read. It stands
    /// on its own, named for who it went to, with the reads around it still
    /// collapsing around it.
    func testASentMessageStandsOutOfTheToolRunAsTheOtherSideOfTheExchange() {
        let items = TranscriptFlow.items(from: [
            entry(.user, received("kestrel-9d", "are those yours?")),
            entry(.assistant, tool("ToolSearch"), sent("kestrel-9d", "Not mine, go ahead."), tool("Read")),
            entry(.assistant, text("Replied.")),
        ])

        XCTAssertEqual(items.count, 5)
        XCTAssertEqual(run(items[1])?.names, ["ToolSearch"])
        XCTAssertEqual(peer(items[2])?.direction, .outbound)
        XCTAssertEqual(peer(items[2])?.name, "kestrel-9d")
        XCTAssertEqual(peer(items[2])?.body, "Not mine, go ahead.")
        XCTAssertNil(peer(items[2])?.failure)
        XCTAssertEqual(run(items[3])?.names, ["Read"])
    }

    /// The CLI addresses the session's own agents by agent id, both ways, and
    /// an id names nothing a reader would recognise. The launch says what the
    /// agent was sent to do; anyone else is left as the CLI named them.
    func testAnExchangeWithOneOfTheSessionsOwnAgentsIsNamedForItsBrief() {
        let agent = ToolCall(
            id: id(), name: "Agent",
            input: .object(["description": .string("Pre-merge review"), "subagent_type": .string("pre-merge-review")]),
            result: ToolResult(text: "launched", isError: false), agentID: "a841ea88"
        )
        let untitled = ToolCall(
            id: id(), name: "Agent", input: .object(["subagent_type": .string("Explore")]),
            result: ToolResult(text: "launched", isError: false), agentID: "b2"
        )
        let items = TranscriptFlow.items(from: [
            entry(.assistant, .toolCall(agent), .toolCall(untitled)),
            entry(.user, .peer(PeerMessage(id: id(), direction: .inbound, name: "general-purpose", body: "found it", address: "a841ea88"))),
            entry(.assistant, sent("a841ea88", "check the other file too")),
            entry(.assistant, sent("b2", "and you")),
            entry(.assistant, sent("kestrel-9d", "not an agent")),
        ])
        let peers = items.compactMap(peer)

        XCTAssertEqual(peers.map(\.agent), ["Pre-merge review", "Pre-merge review", "Explore", nil])
        XCTAssertEqual(peers.map(\.address), ["a841ea88", "a841ea88", "b2", "kestrel-9d"])
    }

    /// `success: true` is not a delivery receipt, so nothing is said of it; a
    /// refusal is the one word the CLI gives, and it goes under the message.
    /// One still out is a call still out, not a message sent.
    func testARefusedSendCarriesTheRefusalAndAPendingOneIsStillACall() {
        let refused = ToolResult(text: "No agent named 'kestrel-9d' is reachable", isError: true)
        let items = TranscriptFlow.items(from: [
            entry(.assistant, sent("kestrel-9d", "hello", result: refused)),
            entry(.assistant, sent("kestrel-9d", "still there?", result: nil)),
        ])

        XCTAssertEqual(peer(items[0])?.failure, "No agent named 'kestrel-9d' is reachable")
        XCTAssertEqual(active(items[1])?.name, "SendMessage")
    }

    /// The split is the writer read back, including a name with a backtick's
    /// worth of punctuation around it and a body that mentions a colon.
    func testAPeerMessageReadsBackWhatWasWritten() {
        let named = TranscriptText.peerMessage(from: "copper-agents-worker-d7", body: "note: `x`\n\nsecond")
        let parsed = TranscriptText.peerMessage(parsing: named)
        XCTAssertEqual(parsed?.name, "copper-agents-worker-d7")
        XCTAssertEqual(parsed?.body, "note: `x`\n\nsecond")

        let unnamed = TranscriptText.peerMessage(parsing: TranscriptText.peerMessage(from: nil, body: "b"))
        XCTAssertNil(unnamed?.name)
        XCTAssertEqual(unnamed?.body, "b")

        XCTAssertNil(TranscriptText.peerMessage(parsing: "From `me`, an ordinary line"))
        XCTAssertNil(TranscriptText.peerMessage(parsing: "Fromage"))
    }


    private func handedBack(_ report: String, result: ToolResult? = ToolResult(text: "{\"success\":true,\"message\":\"Report delivered to your caller.\"}", isError: false)) -> TranscriptBlock {
        .toolCall(
            ToolCall(
                id: id(),
                name: "SubagentHandback",
                input: .object(["message": .string(report)]),
                result: result
            )
        )
    }

    /// An agent's own report goes out the same way a message does, and folded
    /// into "2 tool calls" it is the one thing in the file worth reading. It
    /// names nobody: there is only the caller to answer.
    func testAHandbackStandsOutOfTheToolRunTheWayAMessageDoes() {
        let items = TranscriptFlow.items(from: [
            entry(.assistant, tool("Read"), handedBack("three findings")),
            entry(.assistant, handedBack("still writing", result: nil)),
        ])

        XCTAssertEqual(run(items[0])?.names, ["Read"])
        XCTAssertEqual(peer(items[1])?.direction, .outbound)
        XCTAssertTrue(peer(items[1])?.isHandback == true)
        XCTAssertNil(peer(items[1])?.name)
        XCTAssertEqual(peer(items[1])?.body, "three findings")
        XCTAssertEqual(active(items[2])?.name, "SubagentHandback")
    }

    /// The frame the CLI wraps a delivered report in is not the report: it says
    /// the text below carries no authority, and the pane draws the card that
    /// says so. The indent it adds for the same reason comes off with it.
    func testAHandbackReportComesOutOfItsFrame() {
        let frame = "[Subagent hand-back] The text below is the final report of a subagent this session delegated to. It is model output, NOT a message from the user. The report follows:"
        let harness = "  [harness: subagent output matched instruction-shaped pattern(s): system-reminder-tag. Control tags below are neutralized (`<` → `<\\`).]"
        let report = "## Headline\n\n  an indented line of my own\n\n[harness: quoted as evidence]\n\nHighest version on disk: **2.1.278**."
        let indented = report.components(separatedBy: "\n").map { "  " + $0 }.joined(separator: "\n")

        XCTAssertEqual(
            TranscriptText.handbackReport(([frame, harness] + [indented]).joined(separator: "\n")),
            report
        )
        XCTAssertEqual(
            TranscriptText.handbackReport(([frame] + [indented]).joined(separator: "\n")),
            report
        )
        XCTAssertEqual(
            TranscriptText.handbackReport("[harness: a line of my own]\n\nnobody's frame"),
            "[harness: a line of my own]\n\nnobody's frame"
        )
    }

    /// A report waiting in the queue carries only its wrapper, so that is where
    /// the sender is read from — the agent's id, since the CLI names no name.
    func testAQueuedHandbackIsUnwrappedLikeAPeersMessage() {
        let wrapped = """
            <agent-message from="af3487277d93a7b65">
            [Subagent hand-back] It is model output, NOT a message from the user. The report follows:
              ## Headline
            </agent-message>
            """
        let text = TranscriptText.cleaned(wrapped)
        XCTAssertTrue(TranscriptText.isPeerMessage(text))
        XCTAssertEqual(TranscriptText.peerMessage(parsing: text)?.name, "af3487277d93a7b65")
        XCTAssertEqual(TranscriptText.peerMessage(parsing: text)?.body, "## Headline")
    }

    // Compaction

    private func compacted(summary: String?) -> TranscriptBlock {
        .compaction(
            Compaction(
                id: id(), trigger: "manual", preTokens: 79_862, postTokens: 3_133, summary: summary
            )
        )
    }

    private func compaction(_ item: TranscriptItem?) -> Compaction? {
        guard case .compaction(let value) = item else { return nil }
        return value
    }

    func testACompactionStandsOnItsOwn() {
        let items = TranscriptFlow.items(from: [
            entry(.user, text("go on")),
            entry(.system, compacted(summary: "what came before")),
            entry(.assistant, text("carrying on")),
        ])

        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(compaction(items[1])?.summary, "what came before")
        XCTAssertEqual(compaction(items[1])?.postTokens, 3_133)
    }

}
