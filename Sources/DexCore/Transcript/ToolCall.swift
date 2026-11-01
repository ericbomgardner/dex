import Foundation

/// What a subagent reported when it came back: the CLI's own account of the work
/// it did, written beside the result rather than in it. The terminal keeps this
/// tally beside a running agent and prints it when the agent is done; the pane
/// can only have it once the result lands.
public struct SubagentTotals: Sendable, Hashable {
    public let toolUses: Int
    public let tokens: Int
    public let duration: TimeInterval

    public init(toolUses: Int, tokens: Int, duration: TimeInterval) {
        self.toolUses = toolUses
        self.tokens = tokens
        self.duration = duration
    }

    /// The one line the terminal prints for a finished agent, word for word.
    public var summary: String {
        [
            toolUses == 1 ? "1 tool use" : "\(toolUses) tool uses",
            "\(Format.compact(tokens)) tokens",
            Format.elapsed(duration),
        ].joined(separator: " · ")
    }
}

public struct ToolResult: Sendable, Hashable {
    public let text: String
    public let isError: Bool
    public let answers: [String: String]
    public let notes: [String: String]
    /// Typed in the composer instead of answering the card's questions.
    public let response: String?
    public let subagent: SubagentTotals?
    /// Set when a plan came back rewritten by the approval dialog.
    public let planWasEdited: Bool

    public init(
        text: String,
        isError: Bool,
        answers: [String: String] = [:],
        notes: [String: String] = [:],
        response: String? = nil,
        subagent: SubagentTotals? = nil,
        planWasEdited: Bool = false
    ) {
        self.text = text
        self.isError = isError
        self.answers = answers
        self.notes = notes
        self.response = response
        self.subagent = subagent
        self.planWasEdited = planWasEdited
    }

    /// The CLI's word, written on resume, that a call its session died holding
    /// has no result. Not a failure: nobody knows what it did.
    public var isUnrecorded: Bool {
        isError && TranscriptText.isUnrecordedOutcome(text)
    }
}

/// What became of a plan the session proposed.
public enum PlanOutcome: Sendable, Hashable {
    case waiting
    case approved(edited: Bool)
    case rejected(reason: String?)
}

/// One of the answers a question was asked with, as it was written rather than as
/// the CLI drew it. The mockup is the reason this is worth reading out of the
/// call at all: the dialog has room for one panel and shows only the option its
/// cursor is on, so while a question is up there is nowhere to see the rest —
/// and here they all are, in full, with nothing to press for them.
public struct AskedOption: Sendable, Hashable {
    public let label: String
    public let description: String?
    public let preview: String?

    public init(label: String, description: String? = nil, preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}

public struct AskedQuestion: Sendable, Hashable {
    public let header: String?
    public let question: String
    public let answer: String?
    public let note: String?
    public let options: [AskedOption]

    public init(
        header: String?,
        question: String,
        answer: String?,
        note: String? = nil,
        options: [AskedOption] = []
    ) {
        self.header = header
        self.question = question
        self.answer = answer
        self.note = note
        self.options = options
    }

    /// The option that was picked, where the answer names one. A typed answer
    /// names none, which is the difference between the two.
    public var chosen: AskedOption? {
        answer.flatMap { picked in options.first { $0.label == picked } }
    }

    /// Worth offering to open: options nobody could read while the question was
    /// up, because the dialog explained them under a cursor or drew them one at
    /// a time.
    public var isWorthOpening: Bool {
        options.contains { $0.description != nil || $0.preview != nil }
    }
}

public struct ToolCall: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let input: JSONValue
    /// When the turn that asked for this was written — or, for an agent running
    /// again, the turn whose `SendMessage` woke it. See `TranscriptFlow.marking`.
    public var startedAt: Date?
    /// When the turn that brought it back was.
    public var finishedAt: Date?
    public var result: ToolResult?
    /// The transcript a delegating call set off, where the CLI said which one.
    /// Nil on every other call, and on a delegation whose link was never
    /// written — see `SubagentTranscript` for which those are.
    public var agentID: String?
    /// Came back with a launch receipt rather than a result: the agent works on
    /// in the background, and so does the session that launched it.
    public var isLaunched = false
    /// Its result held a file the CLI took out of the request to fit, so the
    /// model was sent `[media removed: request limit]` in its place.
    public var wasDropped = false

    /// What a dropped call says on its row and in the sentence for its run.
    public static let droppedNote = "too large to send, never seen"

    public init(
        id: String,
        name: String,
        input: JSONValue,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        result: ToolResult? = nil,
        agentID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.input = input
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.result = result
        self.agentID = agentID
    }

    public var isPending: Bool { result == nil }

    public var neverCameBack: Bool { result?.isUnrecorded == true }

    public var isQuestion: Bool { name == "AskUserQuestion" }

    /// A whole conversation's worth of work handed to someone else.
    public var isDelegation: Bool { name == "Task" || name == "Agent" }

    /// What a delegation was sent to do, in the words its row is headed with.
    public var brief: String? {
        guard isDelegation else { return nil }
        return argument("description") ?? argument("subagent_type")
    }

    /// A plan put up for approval.
    public var isPlan: Bool { name == "ExitPlanMode" }

    /// A message to another session or to one of its own agents — the session's
    /// half of a conversation this reader is not in.
    public var isMessage: Bool { name == "SendMessage" }

    /// A subagent's final report, handed to whoever delegated the work. Since
    /// **CLI v2.1.278** the delegating call's own result is a stub pointing
    /// here, so this is where the report is. Read in the agent's own transcript.
    public var isHandback: Bool { name == "SubagentHandback" }

    /// A watch the session armed and left running: it reports what it sees for
    /// as long as it is up, rather than coming back with an answer.
    public var isWatcher: Bool { name == "Monitor" }

    /// The tool's own schema says it carries no plan, reading one out of the file
    /// instead — but the CLI records the whole thing under `plan` anyway, and has
    /// in every version back to **2.1.42**. `planFilePath` arrived beside it in
    /// **2.1.92**, and is the fallback for a call that somehow carries only that.
    public var proposedPlan: String? {
        argument("plan") ?? planFilePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    }

    public var planFilePath: String? { argument("planFilePath") }

    /// Read off the result rather than its text: an approved plan's text is the
    /// whole plan over again, which is not a thing to show under the plan.
    public var planOutcome: PlanOutcome {
        guard let result, !result.isUnrecorded else { return .waiting }
        guard result.isError else { return .approved(edited: result.planWasEdited) }
        return .rejected(reason: Self.rejection(in: result.text))
    }

    /// A rejection carries whatever the user typed instead of just escaping.
    static func rejection(in text: String) -> String? {
        let anchor = "the user said:"
        guard let range = text.range(of: anchor) else { return nil }
        let said = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return said.isEmpty ? nil : said
    }

    /// How long it was gone, for one whose turns both carried a timestamp.
    public var took: TimeInterval? {
        // An unrecorded result is written on resume, so its time spans the death.
        guard let startedAt, let finishedAt, !neverCameBack else { return nil }
        return max(0, finishedAt.timeIntervalSince(startedAt))
    }

    /// What was asked, with what you picked folded back in.
    public var askedQuestions: [AskedQuestion] {
        guard let asked = input.objectValue?["questions"]?.arrayValue else { return [] }

        return asked.compactMap { entry in
            guard let fields = entry.objectValue,
                  let question = fields["question"]?.stringValue,
                  !question.isEmpty
            else { return nil }

            return AskedQuestion(
                header: fields["header"]?.stringValue,
                question: question,
                answer: result?.answers[question] ?? Self.answer(to: question, in: result?.text ?? ""),
                note: result?.notes[question],
                options: Self.options(in: fields["options"])
            )
        }
    }

    private static func options(in value: JSONValue?) -> [AskedOption] {
        guard let listed = value?.arrayValue else { return [] }

        return listed.compactMap { entry in
            guard let fields = entry.objectValue,
                  let label = fields["label"]?.stringValue,
                  !label.isEmpty
            else { return nil }

            return AskedOption(
                label: label,
                description: fields["description"]?.stringValue,
                preview: fields["preview"]?.stringValue
            )
        }
    }

    /// A fallback for when the structured answers are missing: the result text
    /// repeats them as one sentence of `"question"="answer"` pairs, so the
    /// answer is found by anchoring on the question it belongs to.
    private static func answer(to question: String, in reply: String) -> String? {
        guard let anchor = reply.range(of: "\"\(question)\"=\""),
              let close = reply.range(of: "\"", range: anchor.upperBound..<reply.endIndex)
        else { return nil }

        let value = String(reply[anchor.upperBound..<close.lowerBound])
        return value.isEmpty ? nil : value
    }

    public func argument(_ key: String) -> String? {
        guard let value = input.objectValue?[key]?.scalarText, !value.isEmpty else { return nil }
        return value
    }

    /// The one line that stands in for the call in the list. Each arm names the
    /// field that tool actually acts on, so the summary reads as the thing being
    /// done rather than as JSON.
    public var summary: String? {
        trimmed(rawSummary(shortened: true))
    }

    /// What the call was for, rather than what it says. The model writes a line
    /// of its own for a shell command and for an agent, and away from the
    /// conversation — where the command is the thing worth reading, and is what
    /// `summary` leads with — that line is what names the work.
    public var purpose: String? {
        trimmed(argument("description")) ?? summary
    }

    /// The same subject, whole. A command cut to its first line reads as the call
    /// in a list, but where the card is asking you to agree to it, the part
    /// behind the ellipsis is the part being agreed to.
    public var fullSummary: String? {
        trimmed(rawSummary(shortened: false))
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else { return nil }
        return value
    }

    private func rawSummary(shortened: Bool) -> String? {
        switch name {
        case "Read", "Write", "NotebookEdit", "Edit", "MultiEdit":
            argument("file_path").map { Format.shortPath($0) }
        case "Bash", "BashOutput":
            argument("command").map { shortened ? Self.firstLine($0) : $0 } ?? argument("description")
        case "Glob", "Grep":
            [argument("pattern"), argument("path").map { Format.shortPath($0) }]
                .compactMap { $0 }
                .joined(separator: "  in  ")
        case "Task", "Agent":
            brief
        case "WebFetch":
            argument("url")
        case "WebSearch":
            argument("query")
        case "TodoWrite":
            todoSummary
        case "Skill":
            argument("skill") ?? argument("command")
        case "AskUserQuestion":
            questionSummary
        case "ExitPlanMode":
            // The plan is the card below, not the line above it.
            "ready to build"
        default:
            fallbackSummary
        }
    }

    /// The questions are nested a level down, so the top-level scan finds
    /// nothing to quote.
    private var questionSummary: String? {
        guard let questions = input.objectValue?["questions"]?.arrayValue else {
            return argument("question")
        }
        let asked = questions.compactMap { $0.objectValue?["question"]?.stringValue }
        guard let first = asked.first else { return nil }
        return asked.count > 1 ? "\(first) (+\(asked.count - 1) more)" : first
    }

    private var todoSummary: String? {
        guard let todos = input.objectValue?["todos"]?.arrayValue else { return nil }
        let done = todos.filter { $0.objectValue?["status"]?.stringValue == "completed" }.count
        return "\(done)/\(todos.count) done"
    }

    /// An unrecognised tool still reads better with something beside its name.
    /// Sorted so the same call always summarises the same way.
    private var fallbackSummary: String? {
        guard let fields = input.objectValue else { return nil }
        for key in fields.keys.sorted() {
            if let value = fields[key]?.scalarText, !value.isEmpty {
                return Self.firstLine(value)
            }
        }
        return nil
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let newline = trimmed.firstIndex(of: "\n") else { return trimmed }
        return trimmed[..<newline] + " …"
    }

    /// The input as JSON, for the expanded view.
    public var prettyInput: String? {
        guard let fields = input.objectValue, !fields.isEmpty else { return nil }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(input) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
