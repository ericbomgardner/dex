import Foundation

/// The conversation built up from transcript lines, appended to as the file
/// grows. Tool results arrive in the user turn that follows the call; the
/// document folds each one back onto its call rather than showing the tool loop
/// as alternating turns.
public struct TranscriptDocument: Sendable {
    public private(set) var entries: [TranscriptEntry] = []

    /// The model that wrote the newest turn, which a mid-conversation `/model`
    /// moves and the launch flags never do.
    public private(set) var model: String?

    /// What the newest turn read, which is what the next one will read again.
    public private(set) var context: SessionContext?

    /// When the session was last handed something and left to it: the newest
    /// thing you said, or the moment you answered a question or decided a plan.
    /// The clock over the composer counts from here, so it measures the stretch
    /// the session has been working *without you* rather than the age of the
    /// conversation — a question you took five minutes over is five minutes the
    /// session spent waiting, not working.
    ///
    /// A message the session pulled into a turn already running doesn't move it:
    /// that turn started when it started. A permission answered in the CLI's own
    /// dialog is the one handover the transcript doesn't record — the call comes
    /// back when the work is done, not when you allowed it — so that wait is
    /// still counted as work.
    public private(set) var handedOverAt: Date?

    /// What has been sent and not picked up yet. The queue also carries what the
    /// CLI put there on its own account, which is held on to so that a dequeue
    /// naming nothing still takes the right one, and read as nothing.
    public var queued: [QueuedMessage] { queue.filter { !$0.text.isEmpty } }

    /// What the session has taken off its queue and not yet written anywhere.
    /// For a prompt that is the moment before its turn is written; for a
    /// `/compact` it is the whole compaction, tens of seconds with nothing
    /// written at all, and the stand-in for it has already come down on the
    /// enqueue. Cleared by the next record of any other kind, which for a slash
    /// command is a `system` record and not a turn.
    public private(set) var taken: [QueuedMessage] = []

    /// How many messages this reader has sent that the file has caught up on —
    /// what the pane measures its own stand-ins against (`SessionPane.saying`).
    /// Counted rather than matched on text, since the CLI does not record every
    /// message as it was sent: a slash command is not the line you typed.
    ///
    /// Counts up and never down. Each message is counted once, at the first
    /// record that carries it: the enqueue where it went through the queue, the
    /// prompt where it didn't. The prompt or attachment a queued message later
    /// becomes is the same message a second time and adds nothing. Summing the
    /// queue and the prompts instead read one message as two for the stretch
    /// between an absorbed message's attachment and the `remove` behind it —
    /// the CLI writes them in that order — and a high-water mark taken off that
    /// stretch sat one above where the count settled, so the next message sent
    /// only ever climbed back to it and stayed on screen twice.
    ///
    /// The turn a queued message becomes is known by its text, and only a turn
    /// that repeats a queued text word for word is left uncounted. That errs
    /// the safe way. A message counted twice moves the mark up once and every
    /// message after it still climbs past; a message counted short is a
    /// stand-in that never comes down. Counting the queue out instead — one
    /// owed turn per enqueue — was short whenever a queued message never
    /// became a turn at all: a slash command the CLI answers with `system`
    /// records, a message a Stop discarded, the CLI's own idle notice.
    ///
    /// A message from another session is not counted, written or queued: this
    /// reader never sent it, and counted it would retire a stand-in for one
    /// they did.
    public private(set) var heard = 0

    /// Texts counted on their enqueue and not yet seen written out as a turn or
    /// an attachment. One that never is stays here, and costs nothing.
    private var owed: [String] = []

    /// A message written out. Counted unless it is a queued one being written
    /// in its place, which its text says.
    private mutating func heard(written texts: [String]) {
        if let index = owed.firstIndex(where: { texts.contains($0) }) {
            owed.remove(at: index)
        } else {
            heard += 1
        }
    }

    /// tool_use_id → where that call landed, so a later result can find it.
    private var callSites: [String: (entry: Int, block: Int)] = [:]

    /// agent id → the call that launched it. The other way round from
    /// `callSites`, and the only way in for a reading that knows the agent and
    /// not the call — which is `TaskOutput`, whose `task_id` is the agent id.
    private var agentCalls: [String: String] = [:]

    /// A collection that named an agent this document hadn't been introduced to
    /// yet. `early` is the same idea one level down, and this needs its own
    /// because it is keyed by the agent id rather than by a tool_use_id — the
    /// receipt that joins the two is exactly what hasn't been read.
    private var earlyCollections: [String: (task: TranscriptRecord.RawToolResult.CollectedTask, at: Date?)] = [:]

    /// What came back before the call it belongs to was written. The CLI puts
    /// the call first almost always — all but a handful of times in thousands —
    /// but `Skill` is the reliable exception, since the skill it loads is fed to
    /// the model before the turn making the call is flushed, and a scattering of
    /// reads and edits land the same way. Dropped for arriving early, a result
    /// leaves its row spinning for the rest of the conversation.
    private var early: [String: EarlyResult] = [:]

    /// Results no request has carried yet. The CLI strips the oldest files
    /// first, so a drop counts as never seen only in the first request after.
    private var unsent: Set<String> = []

    /// Background agents launched and not yet heard back from. An interrupt
    /// kills every one of them and the CLI writes no notification for any, so
    /// the interruption record is the only word that they are gone.
    private var launched: Set<String> = []

    /// task id → call, for an agent whose notice said it may be interim. The
    /// notice that follows names only the task, and only this lets it land.
    private var interimAgents: [String: String] = [:]

    /// The tools the model's latest step called, which is what a stop "for tool
    /// use" cut off. The CLI's note doesn't say which.
    private var stepCalls: [String] = []
    private var stepAnswered = false

    private struct EarlyResult {
        var result: ToolResult?
        var agentID: String?
        var at: Date?
    }

    /// Every record read so far, by uuid. A transcript can write its whole
    /// history over again partway down, and the second copy relaunches every
    /// background agent whose notice it doesn't repeat.
    private var read: Set<String> = []

    private var queue: [QueuedMessage] = []
    private var queuedSoFar = 0

    /// What the last bare `dequeue` was taken to mean, and where it stood. A
    /// dequeue names nothing, and the head is only a guess: a hosted send goes
    /// in at `priority: "now"` and is taken ahead of the task notifications and
    /// agent reports already waiting. The turn written next says which it was.
    private var dequeued: (message: QueuedMessage, at: Int)?

    /// A subagent's transcript is nothing but sidechain records, so reading one
    /// as a conversation means keeping what the main conversation drops.
    private let keepsSidechain: Bool

    public init(keepsSidechain: Bool = false) {
        self.keepsSidechain = keepsSidechain
    }

    public var isEmpty: Bool { entries.isEmpty }

    public mutating func append(line: Data) {
        guard let record = TranscriptRecord.decode(line) else { return }
        append(record)
    }

    mutating func append(_ record: TranscriptRecord) {
        if let uuid = record.uuid, !read.insert(uuid).inserted { return }

        // A subagent's own turns are a separate conversation. The Task call that
        // spawned it already stands in for the work on this one.
        guard keepsSidechain || record.isSidechain != true else { return }

        switch record.type {
        case "queue-operation": queueOperation(record); return
        case "attachment": absorbedMessage(record); return
        default: taken = []
        }

        if record.isCompactBoundary {
            compacted(record)
            return
        }

        if record.type == "api-request-blob" {
            dropped(record)
            return
        }
        if record.type == "api-request" {
            unsent.removeAll()
            return
        }

        guard let role = record.role else { return }
        let lastDequeued = dequeued
        dequeued = nil

        // The summary the CLI wrote in place of what it compacted away. A user
        // turn in shape, and typed by nobody — read as one it drew as a wall of
        // text and put the handover clock back to the moment of the compaction.
        if record.isCompactSummary == true {
            summarised(record)
            return
        }

        // What the CLI feeds the model of its own accord — a skill's body, the
        // nudge that resumes a session, the path of a pasted image — arrives as
        // a user turn under `isMeta`. Nobody typed it, and where it stands for
        // something the user did the Skill call or the prompt beside it says so.
        // A message from another session arrives the same way, and that one is
        // a message: the session answers it, and dropped here the answer would
        // read as the session moving on its own.
        if record.isMeta == true {
            if role == .user, let origin = record.origin, origin.isPeer {
                peerMessage(origin, id: record.uuid, at: record.at, startsTurn: true)
            }
            return
        }

        // Before the blocks: a turn that leaves nothing to read still says what
        // wrote it. A synthetic turn doesn't — it names no model, so believing it
        // would leave the badge reading `<synthetic>` until the session answers
        // again, which is exactly the stretch where it has stopped answering.
        if role == .assistant, let named = record.message?.model, !named.isEmpty,
           named != TranscriptText.syntheticModel {
            model = named
        }

        if role == .assistant, let carried = record.context {
            context = carried
        }

        var blocks: [TranscriptBlock] = []
        var opened: [String] = []
        let id = record.uuid ?? UUID().uuidString

        for (index, raw) in (record.message?.content ?? []).enumerated() {
            switch raw {
            case .text(let text):
                if role == .user { bringAgentsBack(namedIn: text, at: record.at) }

                let cleaned = role == .user ? TranscriptText.cleaned(text) : text
                guard !cleaned.isEmpty else { continue }

                if record.isInterruption { stopLaunchedAgents(at: record.at) }

                if record.isSynthetic || record.isInterruption {
                    blocks.append(
                        .notice(
                            TranscriptNotice(
                                id: "\(id).\(index)",
                                text: record.isInterruption
                                    ? TranscriptText.canceled(cleaned, calls: stepCalls)
                                    : TranscriptText.unbracketed(cleaned),
                                isError: record.isApiErrorMessage == true
                            )
                        )
                    )
                    continue
                }

                blocks.append(.prose(TranscriptProse(id: "\(id).\(index)", text: cleaned)))

            case .thinking(let text, let isNarration):
                // Models default to `display: "omitted"`, which records the block
                // with no text — dropping the guard fills the pane with empty
                // "Thought" rows. A narration block can be empty too, and the
                // CLI's rule is that an empty one gets ordinary thinking
                // treatment, so this guard has to come first.
                guard !text.isEmpty else { continue }
                let prose = TranscriptProse(id: "\(id).\(index)", text: text)
                blocks.append(isNarration ? .narration(prose) : .thinking(prose))

            case .toolUse(let toolID, let name, let input):
                if stepAnswered {
                    stepCalls = []
                    stepAnswered = false
                }
                stepCalls.append(name)
                callSites[toolID] = (entries.count, blocks.count)
                opened.append(toolID)
                var call = ToolCall(id: toolID, name: name, input: input, startedAt: record.at)
                call.isLaunched = launched.contains(toolID)
                blocks.append(.toolCall(call))

            case .toolResult(let toolUseID, let text, let isError):
                stepAnswered = true
                // Where the CLI said which transcript the agent is writing, hold
                // on to it — the receipt is the last mention of that id, and one
                // turn down it is the only one.
                let launched = TranscriptText.launchedAgentID(in: text)
                if let named = record.toolUseResult?.agentID ?? launched {
                    note(agentID: named, on: toolUseID)
                }

                // Word of an agent this turn went and fetched, rather than word
                // that arrived on its own. It rides on the `TaskOutput` call's
                // result, and settles the delegating call, not this one.
                if let collected = record.toolUseResult?.collected {
                    bringAgentBack(collected, at: record.at)
                }

                // A launch receipt is not a result. The agent is off working, and
                // the notice that it is done comes later, as a turn of its own.
                guard record.toolUseResult?.isLaunch != true, launched == nil else {
                    self.launched.insert(toolUseID)
                    markLaunched(toolUseID)
                    continue
                }

                unsent.insert(toolUseID)
                take(
                    ToolResult(
                        text: text,
                        isError: isError,
                        answers: record.toolUseResult?.answers ?? [:],
                        notes: record.toolUseResult?.notes ?? [:],
                        response: record.toolUseResult?.response,
                        subagent: record.toolUseResult?.subagent,
                        planWasEdited: record.toolUseResult?.planWasEdited ?? false
                    ),
                    for: toolUseID,
                    at: record.at
                )

            case .image(let mediaType, let bytes):
                blocks.append(.image(TranscriptImage(id: "\(id).\(index)", mediaType: mediaType, bytes: bytes)))

            case .other:
                continue
            }
        }

        guard !blocks.isEmpty else { return }

        // A user turn carrying prose is something you said; one carrying only
        // tool results is the loop the session is already in the middle of. The
        // CLI's note that a turn was stopped is written in the same shape as
        // something you typed and is the end of a turn rather than the start of
        // one — read as a message it would put the clock back to zero on the
        // stroke of the Stop it is reporting.
        // A pasted image with nothing typed beside it is something you said too.
        if role == .user, !record.isInterruption,
           blocks.contains(where: { $0.isProse || $0.isImage }) {
            if let at = record.at { handedOverAt = at }
            if blocks.contains(where: \.isProse) {
                let texts = blocks.compactMap { block -> String? in
                    guard case .prose(let prose) = block else { return nil }
                    return prose.text
                }
                if let lastDequeued { retake(lastDequeued, written: texts) }
                heard(written: texts)
            }
        }

        entries.append(TranscriptEntry(id: id, role: role, at: record.at, blocks: blocks))

        // Only now is there an entry to fold a result onto, so anything that
        // came back before the call it belongs to has been waiting for this.
        for toolID in opened { settle(toolID) }
    }

    /// Where the newest compaction sits, so its summary can be folded onto it
    /// when that record is read a moment later.
    private var lastCompaction: (entry: Int, block: Int)?

    /// `postTokens` counts the conversation the CLI kept and not the system
    /// prompt and tool schemas the next request sends with it — a floor of
    /// ~18k on 2.1.314, measured by `compaction-probe.ts`. It still goes on the badge,
    /// marked an estimate: a `/compact` writes no assistant turn, so a badge
    /// that waited for one sat at 500k over a divider saying 5k for as long as
    /// the session was left idle. The next assistant turn is the exact reading.
    private mutating func compacted(_ record: TranscriptRecord) {
        let id = record.uuid ?? UUID().uuidString
        let metadata = record.compactMetadata
        if let post = metadata?.postTokens, post > 0 {
            context = SessionContext(tokens: post, model: context?.model ?? model, isEstimate: true)
        }
        let compaction = Compaction(
            id: id,
            trigger: metadata?.trigger,
            preTokens: metadata?.preTokens,
            postTokens: metadata?.postTokens
        )
        lastCompaction = (entries.count, 0)
        entries.append(
            TranscriptEntry(id: id, role: .system, at: record.at, blocks: [.compaction(compaction)])
        )
    }

    private mutating func summarised(_ record: TranscriptRecord) {
        let written = (record.message?.content ?? []).compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined(separator: "\n")
        let text = Self.unremindered(summary: written)
        guard !text.isEmpty else { return }

        if let site = lastCompaction,
           case .compaction(var compaction) = entries[site.entry].blocks[site.block],
           compaction.summary == nil {
            compaction.summary = text
            entries[site.entry].blocks[site.block] = .compaction(compaction)
            return
        }

        // A summary with no boundary before it has not been seen in any file
        // here; still, the words were written and belong under the divider.
        let id = record.uuid ?? UUID().uuidString
        let compaction = Compaction(id: id, trigger: nil, preTokens: nil, postTokens: nil, summary: text)
        lastCompaction = (entries.count, 0)
        entries.append(
            TranscriptEntry(id: id, role: .system, at: record.at, blocks: [.compaction(compaction)])
        )
    }

    /// Only the 2.1.311+ tools-used reminder goes: not `cleaned`, which folds prose quoting `<command-name>` down to the command.
    static func unremindered(summary: String) -> String {
        TranscriptText.replacing(tag: "system-reminder", in: summary) { reminder in
            reminder.contains("<tools-used-before-summary>")
                ? nil : "<system-reminder>\(reminder)</system-reminder>"
        }
    }

    private mutating func queueOperation(_ record: TranscriptRecord) {
        guard let operation = record.operation else { return }

        // A subagent's report waiting to be delivered is not a message to
        // whoever is reading, so it draws as nothing. It still takes its place
        // in the queue: a `remove` that found no entry of its own would take
        // the head instead, and every later message would come off the wrong one.
        let text = record.queuedText.map {
            TranscriptText.isHandbackDelivery($0) ? "" : TranscriptText.cleaned($0)
        }

        if operation == "enqueue" {
            queuedSoFar += 1
            queue.append(QueuedMessage(id: "queued.\(queuedSoFar)", text: text ?? ""))
            if let text, !text.isEmpty, !TranscriptText.isPeerMessage(text) {
                heard += 1
                owed.append(text)
            }
            return
        }

        // A `remove` says what it took; a `dequeue` doesn't, and takes the head.
        let named = text.flatMap { wanted in queue.firstIndex { $0.text == wanted } }
        guard let index = named ?? queue.indices.first else { return }
        let took = queue.remove(at: index)
        dequeued = operation == "dequeue" ? (took, index) : nil
        if operation == "dequeue", !took.text.isEmpty, !TranscriptText.isPeerMessage(took.text) {
            taken.append(took)
        }
    }

    /// The turn after a dequeue is a queued message that the dequeue's guess
    /// left behind: the guessed entry goes back where it was, and the message
    /// comes off instead of being drawn as still waiting under its own turn.
    private mutating func retake(_ guess: (message: QueuedMessage, at: Int), written texts: [String]) {
        guard !texts.contains(guess.message.text),
              let actual = queue.firstIndex(where: { texts.contains($0.text) })
        else { return }
        queue.remove(at: actual)
        queue.insert(guess.message, at: min(guess.at, queue.count))
    }

    /// A queued message the session took into the turn it was already running.
    /// The CLI records that as an attachment and never as a turn of its own, so
    /// this is the only chance the conversation has to keep it.
    private mutating func absorbedMessage(_ record: TranscriptRecord) {
        guard let attachment = record.attachment,
              attachment.type == "queued_command",
              let prompt = attachment.prompt
        else { return }

        // The CLI queues its own word that an agent is done, and a session busy
        // with a tool call absorbs that word the same way it absorbs yours —
        // into the running turn, written nowhere else. Read as a message it
        // would be dropped here, and the agent spins on for the rest of the
        // conversation.
        if attachment.commandMode == "task-notification" {
            bringAgentsBack(namedIn: prompt, at: record.at)
            return
        }

        guard attachment.commandMode == "prompt" else { return }

        // Another session's message is absorbed the same way, and since v2.1.238
        // it is the only thing that still is.
        if let origin = attachment.origin, origin.isPeer {
            peerMessage(origin, id: record.uuid, at: record.at, startsTurn: false)
            return
        }

        let text = TranscriptText.cleaned(prompt)
        guard !text.isEmpty else { return }
        heard(written: [text])
        userTurn(text, images: attachment.images, id: record.uuid, at: record.at)
    }

    /// A message from another session, drawn as the turn it is and named for
    /// the session that sent it — the wrapper the CLI puts around the body
    /// says the same and is not for reading. Delivered to an idle session it
    /// starts a turn, and the clock moves with it; absorbed into a running one
    /// it doesn't, and the clock stays on whatever started that turn.
    private mutating func peerMessage(
        _ origin: TranscriptRecord.RawOrigin, id: String?, at: Date?, startsTurn: Bool
    ) {
        // Since v2.1.278 a subagent's report arrives by the same door, and it is
        // not addressed to whoever is reading: it answers the model that sent
        // the agent out, and the agent's own conversation already ends with it
        // under the delegation. Dropped before the clock moves — nobody handed
        // this session anything.
        guard !origin.isHandback else { return }

        let body = origin.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !body.isEmpty else { return }

        if startsTurn, let at { handedOverAt = at }
        let id = id ?? UUID().uuidString
        entries.append(
            TranscriptEntry(
                id: id,
                role: .user,
                at: at,
                blocks: [
                    .peer(
                        PeerMessage(
                            id: "\(id).0",
                            direction: .inbound,
                            name: origin.name.flatMap { $0.isEmpty ? nil : $0 },
                            body: body,
                            address: origin.from
                        )
                    )
                ]
            )
        )
    }

    private mutating func userTurn(
        _ text: String, images: [TranscriptRecord.RawBlock], id: String?, at: Date?
    ) {
        let id = id ?? UUID().uuidString
        var blocks: [TranscriptBlock] = [.prose(TranscriptProse(id: "\(id).0", text: text))]
        for (index, raw) in images.enumerated() {
            guard case .image(let mediaType, let bytes) = raw else { continue }
            blocks.append(.image(TranscriptImage(id: "\(id).\(index + 1)", mediaType: mediaType, bytes: bytes)))
        }
        entries.append(TranscriptEntry(id: id, role: .user, at: at, blocks: blocks))
    }

    /// A background agent's call came back the moment it was launched, so the
    /// notice naming it is the only thing that ends the run.
    private mutating func bringAgentsBack(namedIn text: String, at: Date?) {
        for agent in TranscriptText.finishedAgents(in: text) {
            guard let toolUseID = agent.toolUseID ?? agent.taskID.flatMap({ interimAgents[$0] }) else { continue }
            attach(
                ToolResult(
                    text: agent.summary ?? "",
                    isError: agent.failed,
                    subagent: agent.totals
                ),
                to: toolUseID,
                at: at
            )
            if let task = agent.taskID { interimAgents[task] = agent.interim ? toolUseID : nil }
        }
    }

    /// Settled as stopped, not finished. A notification that lands after this
    /// still overwrites it, so an agent that outlived an interrupt would come
    /// back with its own word — none has in any transcript checked.
    private mutating func stopLaunchedAgents(at: Date?) {
        for toolUseID in launched {
            guard let call = written(toolUseID), call.isDelegation, call.isPending else { continue }
            attach(ToolResult(text: "Stopped by the interrupt", isError: true), to: toolUseID, at: at)
        }
        launched = []
    }

    /// A background agent whose result the session went and collected with
    /// `TaskOutput` instead of waiting to be told. **The CLI then writes no
    /// `<task-notification>` for it at all**, so this is the only word in the
    /// file that the agent came back, and without it the launching call spins
    /// for the rest of the conversation.
    ///
    /// Reached through the agent id, since that is all `TaskOutput` names. That
    /// is also the check: an id this conversation never launched settles
    /// nothing, so a result that merely quotes one — a transcript read back, a
    /// probe's output — lands on no row.
    private mutating func bringAgentBack(_ collected: TranscriptRecord.RawToolResult.CollectedTask, at: Date?) {
        guard collected.isOver else { return }

        // Records land in the order the CLI flushed them, so a collection can be
        // read before the receipt that says which call its agent belongs to.
        // Dropped for arriving early it would leave the row spinning for good —
        // which is the whole of the bug this reading exists to fix, reached by a
        // different door.
        guard let toolUseID = agentCalls[collected.taskID] else {
            earlyCollections[collected.taskID] = (collected, at)
            return
        }

        // A notification that already landed carries the CLI's own tally, which
        // this has no way to know. First word wins rather than last.
        guard written(toolUseID)?.isPending != false else { return }

        attach(ToolResult(text: "", isError: collected.failed), to: toolUseID, at: at)
    }

    /// The call as it stands, for a reading that has to look before it writes.
    /// Nil where the call hasn't been written yet, which `attach` answers for.
    private mutating func markLaunched(_ toolUseID: String) {
        guard let site = callSites[toolUseID],
              site.entry < entries.count,
              site.block < entries[site.entry].blocks.count,
              case .toolCall(var call) = entries[site.entry].blocks[site.block]
        else { return }
        call.isLaunched = true
        entries[site.entry].blocks[site.block] = .toolCall(call)
    }

    private func written(_ toolUseID: String) -> ToolCall? {
        guard let site = callSites[toolUseID],
              site.entry < entries.count,
              site.block < entries[site.entry].blocks.count,
              case .toolCall(let call) = entries[site.entry].blocks[site.block]
        else { return nil }
        return call
    }

    /// Fold a result onto its call, and move the handover clock where the call
    /// is one the conversation was waiting on you for.
    private mutating func take(_ result: ToolResult, for toolUseID: String, at: Date?) {
        let answered = attach(result, to: toolUseID, at: at)

        // The two calls that come back because you answered them. What they set
        // off is a stretch of work that starts here, not at the message that led
        // to the question.
        if let answered, answered.isQuestion || answered.isPlan, let at {
            handedOverAt = at
        }
    }

    /// The request as sent, written where it differs from the turns. A file the
    /// CLI took out to fit shows only here: the turn before it still holds it.
    private mutating func dropped(_ record: TranscriptRecord) {
        for case .toolResult(let toolUseID, let text, _) in record.message?.content ?? []
        where unsent.contains(toolUseID)
            && text.split(separator: "\n").contains(Substring(TranscriptText.mediaRemoved)) {
            guard let site = callSites[toolUseID],
                  site.entry < entries.count,
                  site.block < entries[site.entry].blocks.count,
                  case .toolCall(var call) = entries[site.entry].blocks[site.block],
                  !call.wasDropped
            else { continue }
            call.wasDropped = true
            entries[site.entry].blocks[site.block] = .toolCall(call)
        }
    }

    /// The call this was all waiting for has landed.
    private mutating func settle(_ toolUseID: String) {
        guard let waiting = early.removeValue(forKey: toolUseID) else { return }
        if let agentID = waiting.agentID { note(agentID: agentID, on: toolUseID) }
        if let result = waiting.result { take(result, for: toolUseID, at: waiting.at) }
    }

    private mutating func note(agentID: String, on toolUseID: String) {
        // Before the call is found, not after: a receipt that arrives ahead of
        // its call goes on to wait in `early`, and the id it named would be lost
        // for the stretch where the agent is out — which is the whole of it.
        agentCalls[agentID] = toolUseID

        if let waiting = earlyCollections.removeValue(forKey: agentID) {
            bringAgentBack(waiting.task, at: waiting.at)
        }

        guard let site = callSites[toolUseID],
              site.entry < entries.count,
              site.block < entries[site.entry].blocks.count,
              case .toolCall(var call) = entries[site.entry].blocks[site.block]
        else {
            early[toolUseID, default: EarlyResult()].agentID = agentID
            return
        }

        call.agentID = agentID
        entries[site.entry].blocks[site.block] = .toolCall(call)
    }

    /// Returns the call it landed on, for the two the conversation reads
    /// something into beyond the result itself.
    @discardableResult
    private mutating func attach(
        _ result: ToolResult,
        to toolUseID: String,
        at: Date?
    ) -> ToolCall? {
        guard let site = callSites[toolUseID],
              site.entry < entries.count,
              site.block < entries[site.entry].blocks.count,
              case .toolCall(var call) = entries[site.entry].blocks[site.block]
        else {
            early[toolUseID, default: EarlyResult()].result = result
            early[toolUseID]?.at = at
            return nil
        }

        call.result = result
        call.finishedAt = at
        entries[site.entry].blocks[site.block] = .toolCall(call)
        return call
    }
}
