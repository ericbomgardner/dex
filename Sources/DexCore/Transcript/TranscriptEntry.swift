import Foundation

public enum TranscriptRole: Sendable, Hashable {
    case user
    case assistant
    /// The CLI's own record where a turn would go. Today only a compaction.
    case system
}

/// The CLI's word that it compacted the conversation, with the summary it wrote
/// in place of what it dropped. Read off the `compact_boundary` record, which a
/// typed `/compact` and an automatic compaction both write. The `/compact`
/// command turn lands *after* the boundary and its summary in the file, and an
/// automatic one writes no command at all, so the boundary is the only reading.
public struct Compaction: Sendable, Hashable, Identifiable {
    public let id: String
    /// `manual` or `auto`, the CLI's words.
    public let trigger: String?
    /// The CLI's own pair, counting the conversation alone — not the system
    /// prompt and tool schemas the badge counts too, so neither number is the
    /// badge's. `postTokens` is nil on boundaries older than about v2.1.146.
    public let preTokens: Int?
    public let postTokens: Int?
    /// The summary handed to the model, once its record has been read. It lands
    /// one record after the boundary.
    public var summary: String?

    public init(
        id: String, trigger: String?, preTokens: Int?, postTokens: Int?, summary: String? = nil
    ) {
        self.id = id
        self.trigger = trigger
        self.preTokens = preTokens
        self.postTokens = postTokens
        self.summary = summary
    }
}

public struct TranscriptProse: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// A line Claude Code wrote in the place a turn would go: an API error, a
/// session limit, its word that a resumed conversation had nothing left to add,
/// or its note that a turn was stopped. Held apart from prose because the pane
/// draws it as the CLI's line rather than the model's or yours — read at face
/// value, "You've hit your session limit" looks like something the model said,
/// and "[Request interrupted by user]" looks like something you typed.
public struct TranscriptNotice: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String

    /// Whether the turn failed, from the CLI's own flag. A rate limit is worth
    /// the eye; "No response requested." is not a failure.
    public let isError: Bool

    public init(id: String, text: String, isError: Bool) {
        self.id = id
        self.text = text
        self.isError = isError
    }
}

/// One side of a conversation the session is having with someone other than
/// you: a message in from another session, or one it sent out with
/// `SendMessage`. Drawn as an exchange the reader is watching rather than in,
/// since either one read as a prompt looks like something you typed.
public struct PeerMessage: Sendable, Hashable, Identifiable {
    public enum Direction: Sendable, Hashable {
        case inbound
        case outbound
    }

    public let id: String
    public let direction: Direction
    /// The other party's messaging name, or its address where that is all the
    /// call named. Nil for a sender the CLI didn't name.
    public let name: String?
    public let body: String
    /// What the CLI said when a message could not go — `success: true` is not
    /// a delivery receipt, so only a refusal is worth a line.
    public let failure: String?
    /// A subagent's final report rather than a message between sessions. Only
    /// ever the outbound half: the delivery back to the caller is dropped.
    public let isHandback: Bool
    /// What the CLI addresses the other party by: `to` going out, `origin.from`
    /// coming in. For one of the session's own agents, its agent id.
    public let address: String?
    /// The brief of the session's own agent at `address`, as its launch row
    /// shows it. An agent id names nothing a reader would recognise.
    public var agent: String?
    /// When the turn that sent it was written. Outbound only.
    public var sentAt: Date?

    public init(
        id: String,
        direction: Direction,
        name: String?,
        body: String,
        failure: String? = nil,
        isHandback: Bool = false,
        address: String? = nil,
        agent: String? = nil,
        sentAt: Date? = nil
    ) {
        self.id = id
        self.direction = direction
        self.name = name
        self.body = body
        self.failure = failure
        self.isHandback = isHandback
        self.address = address
        self.agent = agent
        self.sentAt = sentAt
    }

    func clipped(to limit: Int) -> PeerMessage {
        PeerMessage(
            id: id, direction: direction, name: name,
            body: TranscriptText.clipped(body, to: limit), failure: failure,
            isHandback: isHandback, address: address, agent: agent, sentAt: sentAt
        )
    }

    /// The call's own words, read off its input. Nil for a call that named no
    /// message, which the tool's schema doesn't allow and the pane won't guess at.
    /// A hand-back is the same shape with nobody to address: it goes to whoever
    /// delegated the work, and the tool names no recipient.
    init?(sent call: ToolCall) {
        guard let body = call.argument("message") else { return nil }
        let failure = call.result.flatMap { $0.isError ? $0.text.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        self.init(
            id: call.id,
            direction: .outbound,
            name: call.isHandback ? nil : call.argument("to"),
            body: body,
            failure: failure.flatMap { $0.isEmpty ? nil : $0 },
            isHandback: call.isHandback,
            address: call.isHandback ? nil : call.argument("to"),
            sentAt: call.startedAt
        )
    }
}

/// An image block, drawn as a line naming it rather than as the picture: the
/// file carries it as base64, often megabytes, and one session can hold
/// hundreds of screenshots. So only the type and size are kept.
public struct TranscriptImage: Sendable, Hashable, Identifiable {
    public let id: String
    /// `image/png`, `image/jpeg`, `image/webp`, as the CLI wrote it.
    public let mediaType: String?
    /// Decoded size, worked out from the length of the base64.
    public let bytes: Int
    /// Pasted with nothing typed beside it, so the image is the whole message
    /// and opens a turn the way a prompt does.
    public var startsTurn: Bool

    public init(id: String, mediaType: String?, bytes: Int, startsTurn: Bool = false) {
        self.id = id
        self.mediaType = mediaType
        self.bytes = bytes
        self.startsTurn = startsTurn
    }

    public var label: String { Self.label(mediaType: mediaType, bytes: bytes) }

    static func label(mediaType: String?, bytes: Int) -> String {
        var kind = "Image"
        if let subtype = mediaType?.split(separator: "/").last, !subtype.isEmpty {
            kind = "\(subtype.uppercased()) image"
        }
        guard bytes > 0 else { return kind }
        return "\(kind), \(size(bytes))"
    }

    static func size(_ bytes: Int) -> String {
        if bytes < 1_000_000 { return "\(max(1, (bytes + 500) / 1_000)) KB" }
        return String(format: "%.1f MB", Double(bytes) / 1_000_000)
    }

    /// What base64 of this length decodes to, without decoding it.
    static func decodedSize(ofBase64 data: String) -> Int {
        let length = data.utf8.count
        let padding = data.utf8.suffix(2).filter { $0 == UInt8(ascii: "=") }.count
        return max(0, length / 4 * 3 - padding)
    }
}

public enum TranscriptBlock: Sendable, Hashable, Identifiable {
    case prose(TranscriptProse)
    /// A picture pasted into a turn. The turn's prose already says `[Image #1]`
    /// where it went; this is the line that says there was one to see.
    case image(TranscriptImage)
    /// A message from another session, kept apart from prose so that nothing
    /// typed here can be read as one.
    case peer(PeerMessage)
    case thinking(TranscriptProse)
    /// Prose the server summarised on the way out — the assistant speaking, not
    /// reasoning. See `NarrationSignature`.
    case narration(TranscriptProse)
    case toolCall(ToolCall)
    case notice(TranscriptNotice)
    case compaction(Compaction)

    public var id: String {
        switch self {
        case .prose(let prose): "text:\(prose.id)"
        case .image(let image): "image:\(image.id)"
        case .peer(let message): "peer:\(message.id)"
        case .thinking(let prose): "think:\(prose.id)"
        case .narration(let prose): "said:\(prose.id)"
        case .toolCall(let call): "tool:\(call.id)"
        case .notice(let notice): "notice:\(notice.id)"
        case .compaction(let compaction): "compact:\(compaction.id)"
        }
    }

    public var isProse: Bool {
        if case .prose = self { return true }
        return false
    }

    public var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

public struct TranscriptEntry: Sendable, Hashable, Identifiable {
    public let id: String
    public let role: TranscriptRole
    public let at: Date?
    public var blocks: [TranscriptBlock]

    public init(id: String, role: TranscriptRole, at: Date?, blocks: [TranscriptBlock]) {
        self.id = id
        self.role = role
        self.at = at
        self.blocks = blocks
    }

    public var isEmpty: Bool { blocks.isEmpty }
}

/// A message sent while the session was working, sitting in the CLI's queue
/// until it is picked up. Nothing else in the transcript stands for it while it
/// waits, and where it is absorbed into the running turn nothing stands for it
/// afterwards either — **CLI v2.1.228**, `Scripts/queued-message-probe.py`.
public struct QueuedMessage: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String

    public init(id: String, text: String) {
        self.id = id
        self.text = text
    }
}

/// A background agent's word that it is done, delivered as a turn of its own
/// rather than as the result of the call that started it. Read off **CLI
/// v2.1.221** — `Scripts/subagent-totals-probe.py` covers the other half of this.
public struct FinishedAgent: Sendable, Hashable {
    /// Nil on the notice that follows an interim one, which names only the task.
    public let toolUseID: String?
    public let taskID: String?
    public let summary: String?
    public let failed: Bool
    public let totals: SubagentTotals?
    /// The agent stopped with its own background work still running; the same
    /// task notifies again when it is really done. **CLI v2.1.299.**
    public let interim: Bool
}

public enum TranscriptText {

    /// Claude Code threads machinery through the user turn — reminders it
    /// injects, word that a background task finished, and the echo of a slash
    /// command. None of it was typed, so none of it belongs in a reading view; a
    /// message sent mid-turn rides in on the same machinery and has to come back
    /// out of it.
    public static func cleaned(_ text: String) -> String {
        var value = text
        value = replacing(tag: "system-reminder", in: value, with: midTurnMessage(in:))
        value = removing(tag: "task-notification", from: value)
        // What the agent's run came to. Inside the notification it goes with the
        // line above; this is for a transcript that set it beside one.
        value = removing(tag: "usage", from: value)
        value = removing(tag: "local-command-stdout", from: value)
        value = removing(tag: "command-message", from: value)

        if let name = content(ofTag: "command-name", in: value) {
            let arguments = content(ofTag: "command-args", in: value) ?? ""
            value = ([name, arguments])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }

        // A message from another session is the whole text: the CLI's preamble
        // before the wrapper and its caution after are not for reading either.
        if let peer = peerMessage(unwrapping: value) { return peer }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A message from another session as one line of text, for the queue —
    /// the one place it is held as nothing but text. Named for the session
    /// that sent it so it isn't read as something typed here; the name is the
    /// sender's messaging name, which is also the address to answer it at.
    public static func peerMessage(from name: String?, body: String) -> String {
        guard let name, !name.isEmpty else { return "\(unnamedPeer)\n\n\(body)" }
        return "\(namedPeer)\(name)`:\n\n\(body)"
    }

    /// Whether a queued message is one of the above rather than something
    /// typed here. Asked of the text because nothing else survives into the
    /// queue. Symmetric with the writer above rather than a guess at its shape
    /// — the two share the openings — and where it is wrong it is wrong about
    /// a line somebody typed to look exactly like one.
    public static func isPeerMessage(_ text: String) -> Bool {
        text.hasPrefix(namedPeer) || text.hasPrefix(unnamedPeer)
    }

    /// The two halves back out of the text above: who sent it, and what they
    /// said. Nil for anything that isn't one. For the queue, where only the
    /// text survives; a written turn carries a `TranscriptBlock.peer` instead.
    public static func peerMessage(parsing text: String) -> (name: String?, body: String)? {
        if text.hasPrefix(unnamedPeer) {
            return (nil, String(text.dropFirst(unnamedPeer.count)).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard text.hasPrefix(namedPeer) else { return nil }
        let rest = text.dropFirst(namedPeer.count)
        guard let close = rest.range(of: "`:") else { return nil }
        let name = String(rest[..<close.lowerBound])
        let body = rest[close.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return (name.isEmpty ? nil : name, body)
    }

    private static let namedPeer = "From `"
    private static let unnamedPeer = "From another session:"


    /// The same, read out of the wrapper the CLI writes around a delivered
    /// message — `<cross-session-message from-name="…">body</cross-session-message>`,
    /// or `<agent-message from="…">` around a subagent's hand-back — for the
    /// records that carry only the text and no `origin`: a queued one.
    /// Whether a delivery is a subagent's report to the model that sent it out
    /// rather than a message between sessions. Read off the wrapper because a
    /// queued one carries nothing else — no `origin`, only the text.
    static func isHandbackDelivery(_ text: String) -> Bool {
        wrapped(text, tag: "agent-message", naming: "from") != nil
    }

    static func peerMessage(unwrapping text: String) -> String? {
        if let sent = wrapped(text, tag: "cross-session-message", naming: "from-name") {
            return peerMessage(from: sent.name, body: sent.body)
        }
        guard let reported = wrapped(text, tag: "agent-message", naming: "from") else { return nil }
        return peerMessage(from: reported.name, body: handbackReport(reported.body))
    }

    private static func wrapped(
        _ text: String, tag: String, naming attribute: String
    ) -> (name: String?, body: String)? {
        guard let open = text.range(of: "<\(tag)"),
              let openEnd = text.range(of: ">", range: open.upperBound..<text.endIndex),
              let close = text.range(of: "</\(tag)>", range: openEnd.upperBound..<text.endIndex)
        else { return nil }

        let opening = text[open.upperBound..<openEnd.lowerBound]
        var name: String?
        if let found = opening.range(of: "\(attribute)=\""),
           let quote = opening.range(of: "\"", range: found.upperBound..<opening.endIndex) {
            name = String(opening[found.upperBound..<quote.lowerBound])
        }

        let body = text[openEnd.upperBound..<close.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        return (name, body)
    }

    /// A subagent's report without the frame the CLI wraps it in: a line saying
    /// the report is model output and carries no authority, sometimes a line of
    /// the harness's own, and the report itself indented by two spaces so that
    /// nothing in it can forge a line of the frame. None of that is the report,
    /// and the pane draws the card the frame is warning about. Anything that
    /// doesn't open with the frame is left exactly as it was.
    public static func handbackReport(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.hasPrefix(handbackLead) == true else { return text }

        lines.removeFirst()
        // Only the harness's own line at the head comes off: a report that
        // quotes one as evidence keeps it.
        while let head = lines.first, head.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        if lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix(harnessLead) == true {
            lines.removeFirst()
        }
        return lines
            .map { $0.hasPrefix(handbackIndent) ? String($0.dropFirst(handbackIndent.count)) : $0 }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let handbackLead = "[Subagent hand-back]"
    private static let harnessLead = "[harness:"
    private static let handbackIndent = "  "

    /// The id in a background agent's launch receipt, which names the transcript
    /// that agent is about to write.
    ///
    /// In the main conversation the CLI records the same id as
    /// `toolUseResult.agentId` and this is only a second reading of it. One turn
    /// down it is the *only* reading: inside a subagent's own transcript
    /// `toolUseResult` is null on every nested spawn, so a receipt that stopped
    /// carrying the id would quietly close every agent below the first — which
    /// is what `SubagentTranscriptTests` pins. **CLI v2.1.227**.
    public static func launchedAgentID(in text: String) -> String? {
        guard text.contains("Async agent launched") else { return nil }
        guard let anchor = text.range(of: "agentId: ") else { return nil }
        let id = text[anchor.upperBound...].prefix { $0.isHexDigit }
        return id.isEmpty ? nil : String(id)
    }

    /// Everything the pane shows is handed to CoreText as one string, and
    /// measuring one costs time quadratic in its length: 64k characters take
    /// 160ms on the main thread, 850k take the better part of a minute. So past
    /// the limit the pane keeps the head and says how much it left behind.
    public static func clipped(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let left = (text.count - limit).formatted(.number.grouping(.automatic))
        return text.prefix(limit) + "\n\n… \(left) more characters"
    }

    /// A message typed while the session was working is delivered to the model
    /// inside a reminder rather than as a turn of its own, so stripping
    /// reminders whole loses the one thing in them that was actually typed.
    /// These two lines are the CLI's, read off **v2.1.220**.
    static let midTurnLead = "The user sent a new message while you were working:"
    static let midTurnNote = "This is how Claude Code surfaces messages the user sends mid-turn"

    static func midTurnMessage(in reminder: String) -> String? {
        let body = reminder.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.hasPrefix(midTurnLead) else { return nil }

        var message = body.dropFirst(midTurnLead.count)
        if let note = message.range(of: midTurnNote) {
            message = message[..<note.lowerBound]
        }
        return message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What the CLI puts where the model id goes on a turn it wrote itself
    /// rather than got from the API. It stands for no model, so a reading that
    /// takes it for one shows the name raw under the composer and keeps showing
    /// it — the badge only moves when a turn names a model. **CLI v2.1.234**.
    public static let syntheticModel = "<synthetic>"

    /// What the CLI sends in place of an image or document once the
    /// conversation's media is over its cap. It is in the request record only.
    static let mediaRemoved = "[media removed: request limit]"

    /// What the CLI writes where a turn was stopped. It goes into the file as a
    /// user turn — the same shape as something you typed — but it is the CLI's
    /// word that the turn ended, not a message anybody owes an answer to. Read
    /// off **v2.1.222**, in two forms: a plain stop, and one that landed on a
    /// tool call, which adds `for tool use`.
    static let interruptionLead = "[Request interrupted by user"

    /// The whole of the line, not the start of one: a turn that opens with the
    /// note and then says more is something a person wrote, and answering it is
    /// still owed.
    public static func isInterruption(_ text: String) -> Bool {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.hasPrefix(interruptionLead) && line.hasSuffix("]") && !line.contains("\n")
    }

    /// What a resume writes as the result of a call the session died holding.
    /// **CLI v2.1.281**; before that the call stayed unanswered.
    static let unrecordedOutcomeLead = "[Tool call interrupted: the session ended before this call's result was recorded"

    public static func isUnrecordedOutcome(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(unrecordedOutcomeLead)
    }

    /// The stop note in the pane's words: what was stopped, rather than the
    /// CLI's "Request interrupted by user for tool use".
    public static func canceled(_ text: String, calls: [String]) -> String {
        guard text.contains("for tool use") else { return "Response canceled" }
        var names: [String] = []
        for call in calls {
            let name = toolName(call)
            if !names.contains(name) { names.append(name) }
        }
        guard let last = names.popLast() else { return "Tool call canceled" }
        return names.isEmpty ? "\(last) canceled" : "\(names.joined(separator: ", ")) and \(last) canceled"
    }

    private static func toolName(_ name: String) -> String {
        if name == "Task" { return "Agent" }
        if name.hasPrefix("mcp__"), let tool = name.split(separator: "__").last { return String(tool) }
        return name
    }

    /// The CLI's note without the brackets it wears in a terminal, where they
    /// are what sets it apart from a message. In a notice card the card does that.
    public static func unbracketed(_ text: String) -> String {
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("["), line.hasSuffix("]"), line.count > 2 else { return line }
        return String(line.dropFirst().dropLast())
    }

    /// The agents a turn brings word of. A background agent's call comes back the
    /// moment it is launched, so this notice is the only thing in the transcript
    /// that says the work itself is over. The tally is looked for inside the
    /// notice and after it: every one sampled sits inside, and
    /// reading only what came after was a tally silently never found.
    public static func finishedAgents(in text: String) -> [FinishedAgent] {
        var agents: [FinishedAgent] = []
        var from = text.startIndex

        while let start = text.range(of: "<task-notification>", range: from..<text.endIndex),
              let end = text.range(of: "</task-notification>", range: start.upperBound..<text.endIndex) {
            let notice = String(text[start.upperBound..<end.lowerBound])
            let next = text.range(of: "<task-notification>", range: end.upperBound..<text.endIndex)
            let beside = String(text[end.upperBound..<(next?.lowerBound ?? text.endIndex)])
            from = end.upperBound

            let id = field("tool-use-id", in: notice).flatMap { $0.isEmpty ? nil : $0 }
            let task = field("task-id", in: notice).flatMap { $0.isEmpty ? nil : $0 }
            guard id != nil || task != nil else { continue }
            let status = field("status", in: notice)
            guard status != nil else { continue }

            agents.append(
                FinishedAgent(
                    toolUseID: id,
                    taskID: task,
                    summary: field("summary", in: notice),
                    failed: status != "completed",
                    totals: totals(in: notice) ?? totals(in: beside),
                    interim: field("note", in: notice)?.contains("interim") == true
                )
            )
        }
        return agents
    }

    private static func totals(in text: String) -> SubagentTotals? {
        guard let usage = content(ofTag: "usage", in: text),
              let toolUses = field("tool_uses", in: usage).flatMap(Int.init),
              let tokens = field("subagent_tokens", in: usage).flatMap(Int.init),
              let milliseconds = field("duration_ms", in: usage).flatMap(Double.init)
        else { return nil }

        return SubagentTotals(toolUses: toolUses, tokens: tokens, duration: milliseconds / 1_000)
    }

    private static func field(_ tag: String, in text: String) -> String? {
        content(ofTag: tag, in: text)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func removing(tag: String, from text: String) -> String {
        replacing(tag: tag, in: text) { _ in nil }
    }

    /// Rewrites every `<tag>…</tag>` span to whatever `keeping` makes of what it
    /// wrapped, and drops the span whole when that is nil. Each pass resumes
    /// past what it wrote, so a kept message carrying the tag keeps it.
    static func replacing(
        tag: String,
        in text: String,
        with keeping: (String) -> String?
    ) -> String {
        var value = text
        let open = "<\(tag)>"
        let close = "</\(tag)>"
        var from = value.startIndex

        while let start = value.range(of: open, range: from..<value.endIndex),
              let end = value.range(of: close, range: start.upperBound..<value.endIndex) {
            let kept = keeping(String(value[start.upperBound..<end.lowerBound])) ?? ""
            let resume = value.distance(from: value.startIndex, to: start.lowerBound) + kept.count
            value.replaceSubrange(start.lowerBound..<end.upperBound, with: kept)
            from = value.index(value.startIndex, offsetBy: resume)
        }
        return value
    }

    static func content(ofTag tag: String, in text: String) -> String? {
        guard let start = text.range(of: "<\(tag)>"),
              let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
