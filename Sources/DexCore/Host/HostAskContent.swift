import Foundation

/// What a card needs out of an ask, once its untyped input is read.
///
/// Off the socket an ask is a list of questions, each with its own options,
/// each option carrying its own mockup — the dialog's shape, not a screen's.
public enum HostAskContent: Equatable, Sendable {
    case questions([HostQuestion])
    case permission(HostPermissionRequest)

    public static func read(_ ask: HostAsk) -> HostAskContent {
        switch ask.kind {
        case .question:
            return .questions(HostQuestion.read(ask.input))
        default:
            return .permission(
                HostPermissionRequest(
                    toolName: ask.toolName,
                    input: ask.input,
                    options: ask.options,
                    drivesScreen: ask.kind == .takeover,
                    screen: ask.screen
                )
            )
        }
    }

    /// Not named for the case it reads, which takes one value and so collides
    /// with it: the compiler picks the property, SourceKit picks the case, and
    /// the call site reads as an error for as long as you have it open.
    public var permissionRequest: HostPermissionRequest? {
        if case .permission(let request) = self { return request }
        return nil
    }
}

public struct HostQuestion: Equatable, Sendable, Identifiable {
    public let question: String
    /// The dialog's own short label for the question; the CLI caps it at twelve
    /// characters, which is why it reads as a chip rather than a heading.
    public let header: String
    public let options: [Option]
    public let multiSelect: Bool

    public var id: String { question }

    public struct Option: Equatable, Sendable, Identifiable {
        public let label: String
        public let detail: String?
        /// A mockup for this option, present only where a visual comparison
        /// helps. Every option's arrives at once, unlike on the screen, where
        /// only the one under the cursor is ever drawn.
        public let preview: String?

        public var id: String { label }

        public init(label: String, detail: String? = nil, preview: String? = nil) {
            self.label = label
            self.detail = detail
            self.preview = preview
        }
    }

    public init(question: String, header: String, options: [Option], multiSelect: Bool) {
        self.question = question
        self.header = header
        self.options = options
        self.multiSelect = multiSelect
    }

    /// Reads whatever is there. A question missing its options is dropped rather
    /// than shown as an unanswerable card, since answering is the only way the
    /// session moves again.
    public static func read(_ input: JSONValue) -> [HostQuestion] {
        guard let questions = input.objectValue?["questions"]?.arrayValue else { return [] }

        return questions.compactMap { entry -> HostQuestion? in
            guard
                let object = entry.objectValue,
                let text = object["question"]?.stringValue,
                let options = object["options"]?.arrayValue
            else { return nil }

            let read = options.compactMap { option -> Option? in
                guard
                    let fields = option.objectValue,
                    let label = fields["label"]?.stringValue
                else { return nil }
                return Option(
                    label: label,
                    detail: fields["description"]?.stringValue,
                    preview: fields["preview"]?.stringValue
                )
            }
            guard !read.isEmpty else { return nil }

            return HostQuestion(
                question: text,
                header: object["header"]?.stringValue ?? "",
                options: read,
                multiSelect: {
                    if case .bool(let flag) = object["multiSelect"] { return flag }
                    return false
                }()
            )
        }
    }
}

public struct HostPermissionRequest: Equatable, Sendable {
    public let toolName: String
    public let input: JSONValue
    public let options: [HostAskOption]
    /// Flagged by the host as taking the pointer or keyboard. The tool is still
    /// Bash; what the card has to say is what the command would do to you.
    public let drivesScreen: Bool
    /// Which line does it, from a host that said.
    public let screen: HostScreenDrive?

    public init(
        toolName: String,
        input: JSONValue,
        options: [HostAskOption],
        drivesScreen: Bool = false,
        screen: HostScreenDrive? = nil
    ) {
        self.toolName = toolName
        self.input = input
        self.options = options
        self.drivesScreen = drivesScreen
        self.screen = screen
    }

    /// What the bar and the notice name a takeover by: the line the host
    /// matched, or, from a host that didn't say which, the command cut to a
    /// line. The first line of a heredoc says only that a script follows.
    public var drivingLine: String? { screen?.line ?? summary }

    /// A plan is not a tool call to agree to, and is decided on the plan itself.
    public var isPlan: Bool { call.isPlan }

    /// What the buttons decide, said as the thing about to be done. The tool's
    /// own name is an identifier, which reads like one on a card whose whole job
    /// is asking you to agree to something — but it is also all there is to go
    /// on for a tool this doesn't know, so that is what the fallback says.
    public var title: String {
        if drivesScreen { return "Drive your screen" }
        return switch toolName {
        case "Bash", "BashOutput": "Run a command"
        case "Read", "NotebookRead": "Read a file"
        case "Write": "Write a file"
        case "Edit", "MultiEdit", "NotebookEdit": "Change a file"
        case "Glob", "Grep": "Search the project"
        case "WebFetch", "WebSearch": "Go out to the web"
        case "Task", "Agent": "Hand this to a subagent"
        case "Skill": "Run a skill"
        // Only ever seen in the seconds before the transcript catches up with
        // the ask; after that the plan card upstairs has it.
        case "ExitPlanMode": "Approve the plan"
        default: "Use \(toolName)"
        }
    }

    /// The command, the path, whatever the tool leads with — read through
    /// `ToolCall` so a call names its subject here the same way the transcript
    /// names it once it has run, rather than by a second scan that knows less.
    public var summary: String? { call.summary }

    /// What the card shows. The list can afford a call cut to one line; the card
    /// cannot, since a heredoc's first line says only that a script follows.
    public var fullSummary: String? { call.fullSummary }

    private var call: ToolCall {
        ToolCall(id: toolName, name: toolName, input: input)
    }
}
