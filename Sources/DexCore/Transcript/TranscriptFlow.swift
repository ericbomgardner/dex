import Foundation

public struct TranscriptReply: Sendable, Hashable {
    public let id: String
    public let blocks: [MarkdownBlock]

    public init(id: String, blocks: [MarkdownBlock]) {
        self.id = id
        self.blocks = blocks
    }
}

/// A plan put up for approval, with its markdown already laid out — the flow is
/// built off the main actor, and the plan is the one tool input long enough for
/// that to matter.
public struct PlanProposal: Sendable, Hashable {
    public let call: ToolCall
    public let blocks: [MarkdownBlock]

    public init(call: ToolCall, blocks: [MarkdownBlock]) {
        self.call = call
        self.blocks = blocks
    }

    public var id: String { call.id }

    public var outcome: PlanOutcome { call.planOutcome }
}

/// Tool calls that ran back to back with nothing said in between — one stretch
/// of work, shown as one line.
public struct TranscriptToolRun: Sendable, Hashable {
    public let calls: [ToolCall]

    public init(calls: [ToolCall]) {
        self.calls = calls
    }

    public var id: String { calls.first?.id ?? "" }

    public var isSingle: Bool { calls.count == 1 }

    /// Which tools ran, first use first, so the collapsed line says what kind of
    /// work this was without being a list of nine identical names.
    public var names: [String] {
        var seen: Set<String> = []
        return calls.map(\.name).filter { seen.insert($0).inserted }
    }

    public var isPending: Bool {
        calls.contains { $0.isPending || $0.neverCameBack }
    }

    public var sentence: String { RunSentence.of(calls) }
}

public enum TranscriptItem: Sendable, Hashable, Identifiable {
    case prompt(TranscriptProse)
    case image(TranscriptImage)
    /// A message between the session and another party, either way.
    case peer(PeerMessage)
    case reply(TranscriptReply)
    case thinking(TranscriptProse)
    /// The assistant speaking through a block the server summarised, drawn as
    /// speech with the summary said out loud. See `NarrationSignature`.
    case narration(TranscriptReply)
    case question(ToolCall)
    case plan(PlanProposal)
    case toolRun(TranscriptToolRun)
    case notice(TranscriptNotice)
    /// A call at the end of the transcript that hasn't come back — what the
    /// session is doing right now, kept out of the collapsed run so it shows.
    case activeTool(ToolCall)
    /// The CLI compacted the conversation here. Not a prompt: nobody typed it,
    /// and it counts toward nothing the composer is waiting to hear back.
    case compaction(Compaction)

    public var id: String {
        switch self {
        case .compaction(let compaction): "compact:\(compaction.id)"
        case .prompt(let prose): "prompt:\(prose.id)"
        case .image(let image): "image:\(image.id)"
        case .peer(let message): "peer:\(message.id)"
        case .reply(let reply): "reply:\(reply.id)"
        case .thinking(let prose): "think:\(prose.id)"
        case .narration(let reply): "said:\(reply.id)"
        case .question(let call): "ask:\(call.id)"
        case .plan(let plan): "plan:\(plan.id)"
        case .toolRun(let run): "run:\(run.id)"
        case .notice(let notice): "notice:\(notice.id)"
        case .activeTool(let call): "live:\(call.id)"
        }
    }
}

/// The conversation flattened for reading: turn boundaries drop away, replies
/// come parsed as markdown, and runs of tool calls collapse into one item.
public enum TranscriptFlow {

    /// A pasted log runs to hundreds of thousands of characters, far past what
    /// anyone reads on to, and laying one out whole locks the pane for seconds.
    static let proseLimit = 24_000

    private static func clipped(_ text: String) -> String {
        TranscriptText.clipped(text, to: proseLimit)
    }

    static func agentBriefs(in entries: [TranscriptEntry]) -> [String: String] {
        var briefs: [String: String] = [:]
        for entry in entries {
            for case .toolCall(let call) in entry.blocks {
                if let id = call.agentID, let brief = call.brief { briefs[id] = brief }
            }
        }
        return briefs
    }

    public static func items(from entries: [TranscriptEntry]) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        var run: [ToolCall] = []
        let briefs = agentBriefs(in: entries)

        func named(_ message: PeerMessage) -> PeerMessage {
            var message = message
            message.agent = message.address.flatMap { briefs[$0] }
            return message
        }

        func flush() {
            guard !run.isEmpty else { return }
            items.append(.toolRun(TranscriptToolRun(calls: run)))
            run = []
        }

        /// Flush, standing every call that hasn't come back out of the run as
        /// it goes: a run is a stretch that finished, and a call with no result
        /// yet is what is happening now. A call with something *said* after it
        /// was abandoned and has been flushed flat already — so everything
        /// still here that hasn't come back is running, and every branch that
        /// goes on to make another call comes through here.
        ///
        /// Told apart by having a result rather than by where they sit, since
        /// calls made together come back in whatever order they finish. Each
        /// keeps its place: a stretch either side of a call still running is
        /// two stretches, and the conversation is read in the order it
        /// happened rather than with the live work gathered at the end.
        func flushSettled() {
            var settled: [ToolCall] = []

            func close() {
                guard !settled.isEmpty else { return }
                items.append(.toolRun(TranscriptToolRun(calls: settled)))
                settled = []
            }

            for call in run {
                guard call.isPending else {
                    settled.append(call)
                    continue
                }
                close()
                items.append(.activeTool(call))
            }

            close()
            run = []
        }

        for entry in entries {
            for block in entry.blocks {
                switch block {
                case .toolCall(let call) where call.isQuestion:
                    flushSettled()
                    items.append(.question(call))

                // The plan is what the turn was for, and a plan still waiting is
                // the session asking rather than working — so it stands on its
                // own whether or not it has come back.
                case .toolCall(let call) where call.isPlan:
                    guard let plan = call.proposedPlan, !plan.isEmpty else {
                        run.append(call)
                        continue
                    }
                    flushSettled()
                    items.append(
                        .plan(
                            PlanProposal(call: call, blocks: Markdown.blocks(in: clipped(plan)))
                        )
                    )

                // The session talking to someone else — another session, or,
                // in an agent's own file, the caller it reports to. Out of the
                // run, since a reply folded into "2 tool calls" is a side of
                // the exchange nobody can read, and a hand-back folded in is
                // the one thing in that file worth reading.
                // Still in the run while it is out: drawn as sent, a call that
                // hasn't come back claims a delivery nothing has confirmed.
                case .toolCall(let call) where call.isMessage || call.isHandback:
                    guard !call.isPending, let sent = PeerMessage(sent: call) else {
                        run.append(call)
                        continue
                    }
                    flushSettled()
                    items.append(.peer(named(sent)))

                // Folded in with the reads around it, a fan-out of three
                // collapses to "3 tool calls" — and an agent still out is running
                // wherever it sits, since a background one works on while the
                // conversation carries on past it.
                case .toolCall(let call) where call.isDelegation:
                    flushSettled()
                    items.append(
                        call.isPending
                            ? .activeTool(call)
                            : .toolRun(TranscriptToolRun(calls: [call]))
                    )

                case .toolCall(let call):
                    run.append(call)

                case .prose(let prose):
                    flush()
                    let text = clipped(prose.text)
                    if entry.role == .user {
                        items.append(.prompt(TranscriptProse(id: prose.id, text: text)))
                    } else {
                        items.append(
                            .reply(TranscriptReply(id: prose.id, blocks: Markdown.blocks(in: text)))
                        )
                    }

                case .image(var image):
                    flush()
                    image.startsTurn = entry.role == .user
                        && !entry.blocks.contains(where: \.isProse)
                        && entry.blocks.first(where: \.isImage)?.id == block.id
                    items.append(.image(image))

                case .peer(let message):
                    flush()
                    items.append(.peer(named(message.clipped(to: proseLimit))))

                case .thinking(let prose):
                    flush()
                    items.append(.thinking(TranscriptProse(id: prose.id, text: clipped(prose.text))))

                case .narration(let prose):
                    flush()
                    items.append(
                        .narration(
                            TranscriptReply(
                                id: prose.id,
                                blocks: Markdown.blocks(in: clipped(prose.text))
                            )
                        )
                    )

                case .notice(let notice):
                    flush()
                    items.append(
                        .notice(
                            TranscriptNotice(
                                id: notice.id,
                                text: clipped(notice.text),
                                isError: notice.isError
                            )
                        )
                    )

                case .compaction(var compaction):
                    flush()
                    compaction.summary = compaction.summary.map(clipped)
                    items.append(.compaction(compaction))
                }
            }
        }

        flushSettled()
        return items
    }

    /// What the transcript shows in flight: the agents still out, and the calls
    /// still waiting at the very end. An ordinary call left pending with the
    /// conversation carried on past it was abandoned, not running.
    public static func running(in items: [TranscriptItem]) -> [ToolCall] {
        items.compactMap { item in
            guard case .activeTool(let call) = item else { return nil }
            return call
        }
    }

    /// The calls the host says are still going, standing back out of the runs
    /// they were folded into.
    ///
    /// A backgrounded command answers the moment it is launched — the receipt
    /// naming the shell is an ordinary result — so the transcript has it as a
    /// call that finished, and then nothing is written for as long as it runs.
    /// The file cannot say otherwise, which is why the host's task set is asked
    /// here rather than the flow deciding on its own.
    ///
    /// Applied over the items rather than while they are built, because the two
    /// change on different clocks: the flow is rebuilt when the file grows, and
    /// this stretch is exactly the one where it doesn't.
    ///
    /// `agents` is the host's tasks, each task id under the call that started
    /// it. A resumed agent is filed under the `SendMessage` that woke it, so it
    /// is found by the id its first call came back with, and its clock runs from
    /// that message: from the first call, it would count every hour the agent
    /// sat finished.
    public static func marking(
        _ items: [TranscriptItem],
        running: Set<String>,
        agents: [String: String] = [:]
    ) -> [TranscriptItem] {
        guard !running.isEmpty || !agents.isEmpty else { return items }
        let taskIDs = Set(agents.values)

        func isResumed(_ call: ToolCall) -> Bool {
            !running.contains(call.id) && call.isDelegation && call.agentID.map(taskIDs.contains) == true
        }

        func isRunning(_ call: ToolCall) -> Bool {
            running.contains(call.id) || isResumed(call)
        }

        var sent: [String: Date] = [:]
        for item in items {
            switch item {
            case .peer(let message): sent[message.id] = message.sentAt
            case .toolRun(let run): for call in run.calls where call.isMessage { sent[call.id] = call.startedAt }
            case .activeTool(let call) where call.isMessage: sent[call.id] = call.startedAt
            default: break
            }
        }

        func marked(_ call: ToolCall) -> ToolCall {
            guard isResumed(call), let agentID = call.agentID else { return call }
            var woken = call
            woken.startedAt = agents.lazy.compactMap { $0.value == agentID ? sent[$0.key] : nil }.first
            return woken
        }

        return items.flatMap { item -> [TranscriptItem] in
            guard case .toolRun(let run) = item,
                  run.calls.contains(where: isRunning)
            else { return [item] }

            var split: [TranscriptItem] = []
            var settled: [ToolCall] = []

            func close() {
                guard !settled.isEmpty else { return }
                split.append(.toolRun(TranscriptToolRun(calls: settled)))
                settled = []
            }

            for call in run.calls {
                guard isRunning(call) else {
                    settled.append(call)
                    continue
                }
                close()
                split.append(.activeTool(marked(call)))
            }

            close()
            return split
        }
    }

    /// Work the session started and walked away from: the call came back and
    /// the thing it started is still going. Told from the session's own call in
    /// flight by having a result — that one is the session working, which the
    /// strip already has a line for, and naming it twice reads as two things
    /// happening.
    public static func backgroundWork(in items: [TranscriptItem]) -> [ToolCall] {
        running(in: items).filter { !$0.isPending && !$0.isDelegation }
    }

    /// Only the agents, oldest first. They are the one call worth naming away
    /// from the line it is on: several run at once, they run for minutes, and a
    /// background one is still out while the conversation carries on past it.
    public static func agents(in items: [TranscriptItem]) -> [ToolCall] {
        running(in: items).filter(\.isDelegation)
    }

    /// What the session's own turn is held on: the calls in flight, less the
    /// agents it launched into the background. Those run on beside the turn
    /// rather than in it, so a session with three of them out can still be
    /// thinking or writing, and a line that read them as the work hid that.
    public static func waitedOn(in items: [TranscriptItem]) -> [ToolCall] {
        running(in: items).filter { !$0.isLaunched }
    }

    /// Whether everything the turn is held on is an agent — the session has
    /// handed the work out and is waiting on it rather than doing any of its
    /// own. Nothing held at all is not waiting: a session between calls is
    /// thinking, which is work it is doing itself.
    public static func isWaitingOnAgents(in items: [TranscriptItem]) -> Bool {
        let held = waitedOn(in: items)
        return !held.isEmpty && held.allSatisfy(\.isDelegation)
    }
}
