import Foundation

/// What the sidecar host says, and what it will be told.
///
/// Deliberately not the transcript: a hosted session writes to the same
/// `~/.claude/projects` file the pane already watches, so this wire carries only
/// what that file cannot say — an ask still on screen, a status not yet written,
/// and the session id binding a row to its file.
public enum HostProtocol {
    /// Bumped only for a change the app and host cannot both survive.
    public static let version = 1
}

// MARK: - Vocabulary

/// The host's own words for what a session is doing, which are not the words
/// `claude agents --json` uses for the same thing — hence the prefix.
public enum HostSessionState: OpenEnum {
    case starting
    case running
    /// The CLI is summarising the conversation to shrink it — a stretch of
    /// running that writes nothing and answers nothing, off the SDK's own
    /// `status: "compacting"`. **SDK 0.3.268**; `compaction-probe.ts`.
    case compacting
    case idle
    case asking
    case done
    case failed
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "starting": self = .starting
        case "running": self = .running
        case "compacting": self = .compacting
        case "idle": self = .idle
        case "asking": self = .asking
        case "done": self = .done
        case "error": self = .failed
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .starting: "starting"
        case .running: "running"
        case .compacting: "compacting"
        case .idle: "idle"
        case .asking: "asking"
        case .done: "done"
        case .failed: "error"
        case .unknown(let value): value
        }
    }

    /// A session the app should stop expecting anything further from.
    public var isFinished: Bool {
        switch self {
        case .done, .failed: true
        default: false
        }
    }
}

public enum HostAskKind: OpenEnum {
    case question
    case permission
    /// A Bash call the host's own hook flagged as driving the pointer or
    /// keyboard. Answered like a permission, but the app decides some of these
    /// itself: allowed while nobody is at the keyboard, asked otherwise.
    case takeover
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "question": self = .question
        case "permission": self = .permission
        case "takeover": self = .takeover
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .question: "question"
        case .permission: "permission"
        case .takeover: "takeover"
        case .unknown(let value): value
        }
    }
}

public enum HostAskOptionKind: OpenEnum {
    case allowOnce
    case allowAlways
    case rejectOnce
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "allow_once": self = .allowOnce
        case "allow_always": self = .allowAlways
        case "reject_once": self = .rejectOnce
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .allowOnce: "allow_once"
        case .allowAlways: "allow_always"
        case .rejectOnce: "reject_once"
        case .unknown(let value): value
        }
    }

    public var isAllow: Bool {
        switch self {
        case .allowOnce, .allowAlways: true
        default: false
        }
    }

    /// What the option decides when what is being decided is a plan. The host
    /// names these for tool calls in general — "Allow", "Deny" — and neither is
    /// what agreeing to a plan is called. Nil where there is nothing better to
    /// say than the host's own name.
    public var planName: String? {
        switch self {
        case .allowOnce: "Approve"
        case .rejectOnce: "Keep planning"
        default: nil
        }
    }
}

// MARK: - Payloads

public struct HostAskOption: Codable, Hashable, Sendable {
    public let optionId: String
    public let name: String
    public let kind: HostAskOptionKind

    public init(optionId: String, name: String, kind: HostAskOptionKind) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

public struct HostSessionSummary: Codable, Hashable, Sendable {
    public let key: String
    /// Absent until `session.init`: the host answers `start` before the SDK has
    /// opened the transcript, so a row exists before its file does.
    public var sessionId: String?
    public var cwd: String
    public var name: String?
    /// Nil for a session started by hand, and for every session on a host that
    /// predates the field.
    public var origin: SessionOrigin?
    public var state: HostSessionState
    public var model: String?
    public var permissionMode: String
    /// What the session thinks at, where anything has said. Nil is not a level
    /// — it is nobody having asked, and the settings files resolving one the
    /// host cannot read back.
    public var effort: String?
    /// The style the CLI resolved for the session, which is not always the one
    /// asked for. Bound at launch by this app — the SDK can move one on a
    /// running session since CLI v2.1.278, and the app doesn't offer that yet.
    public var outputStyle: String?
    public let startedAt: String
    /// When the host last had news of the session. Optional because a host left
    /// running by an older build of this app doesn't send it, and the welcome it
    /// does send is otherwise perfectly usable.
    public var lastActivityAt: String?
    /// The commands this session's CLI will run. The CLI ships a great many it
    /// can only open inside a terminal and leaves those out of its own list, so
    /// this is the only word for which of them are worth offering. Nil where
    /// nobody has said — a host from before this was on the wire, or a session
    /// that hasn't reached its first `init` — and nil means offer everything,
    /// since a menu that greys the lot on an old host is worse than one that
    /// greys nothing.
    public var commands: [String]?
    /// Each MCP server as this session's CLI sees it. Nil where nobody has said.
    public var mcpServers: [HostMcpServer]?

    public init(
        key: String,
        sessionId: String?,
        cwd: String,
        name: String?,
        origin: SessionOrigin? = nil,
        state: HostSessionState,
        model: String?,
        permissionMode: String,
        effort: String? = nil,
        outputStyle: String? = nil,
        startedAt: String,
        lastActivityAt: String? = nil,
        commands: [String]? = nil,
        mcpServers: [HostMcpServer]? = nil
    ) {
        self.key = key
        self.sessionId = sessionId
        self.cwd = cwd
        self.name = name
        self.origin = origin
        self.state = state
        self.model = model
        self.permissionMode = permissionMode
        self.effort = effort
        self.outputStyle = outputStyle
        self.startedAt = startedAt
        self.lastActivityAt = lastActivityAt
        self.commands = commands
        self.mcpServers = mcpServers
    }
}

/// One MCP server as a session's CLI reports it. `status` is the CLI's word —
/// `connected`, `failed`, `needs-auth`, `pending`, `disabled` — kept as text so
/// one added later still shows.
public struct HostMcpServer: Codable, Hashable, Sendable {
    public let name: String
    public let status: String
    /// Only from `mcpServerStatus()`; the `init` frame carries none.
    public var error: String?

    public init(name: String, status: String, error: String? = nil) {
        self.name = name
        self.status = status
        self.error = error
    }
}

public struct HostAsk: Codable, Hashable, Sendable, Identifiable {
    public let askId: String
    public let key: String
    public let kind: HostAskKind
    public let toolName: String
    /// Whole rather than modelled: a question's questions live in here, and so
    /// does every tool's own input shape.
    public let input: JSONValue
    /// Empty on a question, whose choices are inside `input`.
    public let options: [HostAskOption]
    /// On a takeover, which line of the command the host read as driving the
    /// screen. Nil from a host older than the field, and from any other kind
    /// of ask; the card then falls back to the command cut to a line.
    public let screen: HostScreenDrive?

    public var id: String { askId }

    public init(
        askId: String,
        key: String,
        kind: HostAskKind,
        toolName: String,
        input: JSONValue,
        options: [HostAskOption],
        screen: HostScreenDrive? = nil
    ) {
        self.askId = askId
        self.key = key
        self.kind = kind
        self.toolName = toolName
        self.input = input
        self.options = options
        self.screen = screen
    }
}

/// The line of a command that drives the screen, and what in it said so — the
/// `DEX_DRIVES_SCREEN=1` mark, or the habit the host's net caught. A takeover's
/// command can be a script with that line at the very bottom, past the fold of
/// the card, so this is what the card and the bar name rather than its first.
public struct HostScreenDrive: Codable, Hashable, Sendable {
    public let line: String
    public let match: String

    public init(line: String, match: String) {
        self.line = line
        self.match = match
    }
}

public struct HostWelcome: Codable, Hashable, Sendable {
    public let host: String
    /// What the host process loaded, frozen at its start.
    public let sdk: String
    /// What a host started now would load. Optional because a host older than
    /// the field doesn't send it, and a welcome that fails to decode is an app
    /// that cannot connect until the host is replaced — which is the one thing
    /// this pair exists to avoid making necessary.
    public let sdkOnDisk: String?
    /// The commit the host's bundle was built from, stamped by make-app.sh.
    /// Nil from a host older than the field or one run from a checkout, and
    /// nil never reads as stale — see `HostStaleness`.
    public let build: String?
    /// Whether the host holds work a replace would lose. Optional because a host
    /// older than the field can't say — and nil never reads as safe to stop, so
    /// the automatic replace waits for a host new enough to answer it.
    public let busy: Bool?
    public let modes: [String]
    /// What an `effort` request will take. Optional for the reason `sdkOnDisk`
    /// is: a host older than the field sends none, and a welcome that fails to
    /// decode is an app that cannot connect until the host is replaced.
    public let efforts: [String]?
    /// Every output style the CLI has, as the newest session found them. Empty
    /// on a host that has not started one — the list lives on a running
    /// session's `initializationResult()` and nowhere else — so the app keeps
    /// the last one it heard rather than emptying its picker.
    public let outputStyles: [String]?
    /// The host's pid. A hosted session has no process of its own, and a row
    /// without one is a row `TranscriptWatcher` declines to watch.
    public let pid: Int
    public let sessions: [HostSessionSummary]
    /// Asks parked while the app was away, so a question raised overnight is on
    /// screen at launch rather than waiting for the session to repeat itself.
    public let pending: [HostAsk]

    public let protocolVersion: Int

    /// What this host serves beyond sessions, such as "rename". Empty from a
    /// host older than the field, which is the same answer as a host that
    /// serves none.
    public var capabilities: [String] = []

    /// The host's own `~/.claude`, after `CLAUDE_CONFIG_DIR`. Every path on
    /// this wire is inside it.
    public var configDir: String?

    public var servesRename: Bool { capabilities.contains("rename") }

    private enum CodingKeys: String, CodingKey {
        case host, sdk, sdkOnDisk, build, busy, modes, efforts, outputStyles, pid, sessions, pending
        case capabilities, configDir
        case protocolVersion = "protocol"
    }

    public init(
        host: String,
        sdk: String,
        sdkOnDisk: String?,
        build: String?,
        busy: Bool?,
        modes: [String],
        efforts: [String]?,
        outputStyles: [String]?,
        pid: Int,
        sessions: [HostSessionSummary],
        pending: [HostAsk],
        protocolVersion: Int,
        capabilities: [String] = [],
        configDir: String? = nil
    ) {
        self.host = host
        self.sdk = sdk
        self.sdkOnDisk = sdkOnDisk
        self.build = build
        self.busy = busy
        self.modes = modes
        self.efforts = efforts
        self.outputStyles = outputStyles
        self.pid = pid
        self.sessions = sessions
        self.pending = pending
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
        self.configDir = configDir
    }

    /// Written out rather than synthesized for `capabilities` alone: a host
    /// older than the field sends none, and reading that as a decode failure
    /// is an app that cannot connect at all.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(String.self, forKey: .host)
        sdk = try container.decode(String.self, forKey: .sdk)
        sdkOnDisk = try container.decodeIfPresent(String.self, forKey: .sdkOnDisk)
        build = try container.decodeIfPresent(String.self, forKey: .build)
        busy = try container.decodeIfPresent(Bool.self, forKey: .busy)
        modes = try container.decode([String].self, forKey: .modes)
        efforts = try container.decodeIfPresent([String].self, forKey: .efforts)
        outputStyles = try container.decodeIfPresent([String].self, forKey: .outputStyles)
        pid = try container.decode(Int.self, forKey: .pid)
        sessions = try container.decode([HostSessionSummary].self, forKey: .sessions)
        pending = try container.decode([HostAsk].self, forKey: .pending)
        protocolVersion = try container.decode(Int.self, forKey: .protocolVersion)
        capabilities = try container.decodeIfPresent([String].self, forKey: .capabilities) ?? []
        configDir = try container.decodeIfPresent(String.self, forKey: .configDir)

    }
}

public struct HostSessionInit: Codable, Hashable, Sendable {
    public let key: String
    public let sessionId: String
    public let cwd: String
    /// The start's own name and origin. An app already connected when another
    /// client starts a session never gets that session's summary, so this is
    /// its only word on either. Optional for the same reason `commands` is.
    public var name: String? = nil
    public var origin: SessionOrigin? = nil
    /// Fixed for the session's life — the SDK cannot move a running
    /// conversation's model, so the picker binds at launch or not at all.
    public let model: String?
    public let permissionMode: String
    /// Bound at launch too, but by this app rather than by the SDK: since CLI
    /// v2.1.278 `applyFlagSettings` moves a running session's style from the
    /// next turn, and the app keeps one app-wide pick instead of a dial. The
    /// CLI's own word for what it resolved, so a style named after no file on
    /// disk says here where it actually landed — and this is where a style that
    /// had been moved would be read back.
    public let outputStyle: String?
    /// What the session thinks at, which unlike the two above can be moved
    /// while it runs. Restated on every turn's init, so a session dialled
    /// somewhere by another window is read back here as well as off
    /// `session.effort`. Nil is nobody having asked — the settings files
    /// resolved a level and neither end can read back which.
    ///
    /// Optional for the same reason `commands` is: a host that predates the
    /// field sends none, and nil there must leave what is already known alone
    /// rather than walk a dialled session back to Default.
    public var effort: String? = nil
    public let tools: [String]
    /// Optional for the same reason the summary's is: a host that predates this
    /// field sends none, and the event still has to decode.
    public var commands: [String]? = nil
    /// Optional for the same reason.
    public var mcpServers: [HostMcpServer]? = nil
}

/// What a session started in a directory would resolve to, with none of the
/// app's own picks in it — the app's go in the flag layer, above every file
/// behind this, so leaving them out is what makes this the meaning of Default
/// rather than a record of the last thing picked.
///
/// Either may be nil, where nothing in the cascade sets it. Nil is not a
/// failure and not a level: it is the CLI falling back to something of its own,
/// and the picker says Default and stops rather than naming a value no file
/// asked for.
public struct HostDefaults: Codable, Hashable, Sendable {
    public let cwd: String
    public let outputStyle: String?
    public let effort: String?

    /// Three states, not two, because the chip asserts a name on one of them
    /// and nil would have covered the other two without telling them apart: a
    /// host from before the field, or without the resolver, never answers —
    /// and "nobody answered" must not read as "no file names one", which is
    /// what lets the built-in default be named at all.
    public enum Model: Hashable, Sendable {
        case unanswered
        case unnamed
        case named(String)
    }

    public let model: Model

    /// Every file that names an effort, highest precedence first. Nil is a host
    /// from before the field, which leaves `effort` as the only answer.
    public let efforts: [EffortSource]?

    public struct EffortSource: Codable, Hashable, Sendable {
        public let source: String
        public let effort: String?
        public let models: [String: String]

        public init(source: String, effort: String? = nil, models: [String: String] = [:]) {
            self.source = source
            self.effort = effort
            self.models = models
        }
    }

    public init(
        cwd: String,
        outputStyle: String?,
        effort: String?,
        model: Model = .unanswered,
        efforts: [EffortSource]? = nil
    ) {
        self.cwd = cwd
        self.outputStyle = outputStyle
        self.effort = effort
        self.model = model
        self.efforts = efforts
    }

    private enum CodingKeys: String, CodingKey {
        case cwd, outputStyle, effort, model, efforts
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cwd = try container.decode(String.self, forKey: .cwd)
        outputStyle = try container.decodeIfPresent(String.self, forKey: .outputStyle)
        effort = try container.decodeIfPresent(String.self, forKey: .effort)
        efforts = try container.decodeIfPresent([EffortSource].self, forKey: .efforts)
        if container.contains(.model) {
            model = try container.decodeIfPresent(String.self, forKey: .model)
                .map(Model.named) ?? .unnamed
        } else {
            model = .unanswered
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cwd, forKey: .cwd)
        try container.encodeIfPresent(outputStyle, forKey: .outputStyle)
        try container.encodeIfPresent(effort, forKey: .effort)
        try container.encodeIfPresent(efforts, forKey: .efforts)
        switch model {
        case .unanswered: break
        case .unnamed: try container.encodeNil(forKey: .model)
        case .named(let name): try container.encode(name, forKey: .model)
        }
    }
}

public struct HostReply: Codable, Hashable, Sendable {
    public let id: String
    public let ok: Bool
    public let key: String?
    public let error: String?
    /// A `side` question's answer.
    public var response: String?
    /// Where an `mcpLogin` has to be finished.
    public var authUrl: String?
    /// False where an `mcpLogin` is finished somewhere the CLI hears nothing
    /// from, so a reconnect is still needed after.
    public var reconnects: Bool?
}

public struct SideExchange: Codable, Hashable, Sendable {
    public let question: String
    public let response: String

    public init(question: String, response: String) {
        self.question = question
        self.response = response
    }
}

public struct HostSessionResult: Codable, Hashable, Sendable {
    public let key: String
    public let subtype: String
    public let costUSD: Double?
    public let turns: Int?
}

// MARK: - Events

/// One piece of work a session has running that can be ended on its own.
///
/// `toolUseID` is what makes it addressable: the transcript knows an agent by
/// the call that spawned it and has never heard of a task id, so a task without
/// one belongs to no row the app can draw. Read off `task_started`, which is the
/// only word for a task that is still going — the notification carrying the same
/// pair arrives when it is over.
public struct HostTask: Sendable, Hashable, Decodable {
    public let taskId: String
    public let toolUseId: String?
    public let description: String?
    /// The tool call this came from, where the host saw one. Absent from a host
    /// older than the field, and nil has to read as work: a task nobody can name
    /// is the session's own, and calling it a watcher would stop the spinner on
    /// a running agent.
    public let tool: String?

    public init(taskId: String, toolUseId: String?, description: String? = nil, tool: String? = nil) {
        self.taskId = taskId
        self.toolUseId = toolUseId
        self.description = description
        self.tool = tool
    }

    /// A `Monitor` watches a file for as long as its timeout allows, with the
    /// turn that armed it long over. It is in the set so the pane can list it
    /// and stop it, and out of the row's count so the row reads idle.
    public var isWatcher: Bool { tool == "Monitor" }
}

/// A hosted session's `start_session` call, handed to the app to start the way
/// its composer would. Answered with `HostRequest.launched`.
public struct HostLaunch: Decodable, Hashable, Sendable {
    public let launchId: String
    public let cwd: String
    public let prompt: String
    public let name: String?
    /// The asking session's key.
    public let parent: String

    public init(launchId: String, cwd: String, prompt: String, name: String? = nil, parent: String) {
        self.launchId = launchId
        self.cwd = cwd
        self.prompt = prompt
        self.name = name
        self.parent = parent
    }
}

public enum HostEvent: Sendable, Hashable {
    case reply(HostReply)
    case welcome(HostWelcome)
    case launch(HostLaunch)
    case sessionInit(HostSessionInit)
    case sessionStatus(key: String, state: HostSessionState)
    /// The mode the CLI says the session is in, whenever that has moved. Sent
    /// for a change the app asked for and for one the CLI made itself, which is
    /// what approving a plan is.
    case sessionMode(key: String, permissionMode: String)
    /// What a session thinks at, whenever the host has moved it. Its own word
    /// rather than the CLI's: nothing restates the effort the way a `system`
    /// message restates the mode, so this says what `applyFlagSettings` took.
    case sessionEffort(key: String, effort: String)
    /// The session's MCP servers, whenever their statuses move. A level: it
    /// replaces what is held.
    case sessionMcp(key: String, servers: [HostMcpServer])
    /// Every output style the CLI has, whenever the host learns a different set.
    /// Not about any one session, though a session is what found it.
    case outputStyles([String])
    /// What Default means for a directory — the settings cascade merged with
    /// nothing of the app's own in it. Keyed by directory because a project can
    /// hold settings of its own, so the same app has one answer per folder.
    case defaults(HostDefaults)
    /// Everything the session has running that can be stopped on its own,
    /// whenever that set changes. A level rather than a pair of edges: what the
    /// app holds is replaced by this, so a bookend it never heard can't leave a
    /// Stop button on a row whose agent came back.
    case sessionTasks(key: String, tasks: [HostTask])
    case ask(HostAsk)
    case askWithdrawn(askId: String, key: String)
    case sessionResult(HostSessionResult)
    case sessionExit(key: String, reason: String)
    /// A host newer than the app. Read past it: dropping the connection over an
    /// event we don't know yet would make every host upgrade a breaking one.
    case unrecognised(type: String)

    /// Whether hearing this should move the session's row up the list. The
    /// row bumps on conversation — turn edges and questions — not on news
    /// *about* the session: a subagent starting or finishing, a mode
    /// restated, an ask withdrawn. Stamping every keyed event put a row at
    /// the top of the list each time an agent came or went, for work that
    /// had said nothing yet.
    public var movesRowClock: Bool {
        switch self {
        case .sessionInit, .sessionStatus, .ask, .sessionResult: true
        case .sessionMode, .sessionEffort, .sessionMcp, .outputStyles, .defaults, .sessionTasks,
            .askWithdrawn, .sessionExit, .reply, .welcome, .launch, .unrecognised:
            false
        }
    }

    /// The session an event is about, where it is about one.
    public var sessionKey: String? {
        switch self {
        case .sessionInit(let start): start.key
        case .sessionStatus(let key, _): key
        case .sessionMode(let key, _): key
        case .sessionEffort(let key, _): key
        case .sessionMcp(let key, _): key
        case .sessionTasks(let key, _): key
        case .ask(let ask): ask.key
        case .askWithdrawn(_, let key): key
        case .sessionResult(let result): result.key
        case .sessionExit(let key, _): key
        case .outputStyles, .defaults, .reply, .welcome, .launch, .unrecognised:
            nil
        }
    }
}

extension HostEvent: Decodable {
    private enum Key: String, CodingKey {
        case type, key, state, askId, reason, permissionMode, effort, styles, tasks, servers, text
    }

    public init(from decoder: any Decoder) throws {
        let keyed = try decoder.container(keyedBy: Key.self)
        let type = try keyed.decode(String.self, forKey: .type)
        let whole = try decoder.singleValueContainer()

        switch type {
        case "reply":
            self = .reply(try whole.decode(HostReply.self))
        case "welcome":
            self = .welcome(try whole.decode(HostWelcome.self))
        case "launch":
            self = .launch(try whole.decode(HostLaunch.self))
        case "session.init":
            self = .sessionInit(try whole.decode(HostSessionInit.self))
        case "session.status":
            self = .sessionStatus(
                key: try keyed.decode(String.self, forKey: .key),
                state: try keyed.decode(HostSessionState.self, forKey: .state)
            )
        case "session.mode":
            self = .sessionMode(
                key: try keyed.decode(String.self, forKey: .key),
                permissionMode: try keyed.decode(String.self, forKey: .permissionMode)
            )
        case "session.effort":
            self = .sessionEffort(
                key: try keyed.decode(String.self, forKey: .key),
                effort: try keyed.decode(String.self, forKey: .effort)
            )
        case "session.mcp":
            self = .sessionMcp(
                key: try keyed.decode(String.self, forKey: .key),
                servers: try keyed.decodeIfPresent([HostMcpServer].self, forKey: .servers) ?? []
            )
        case "host.defaults":
            self = .defaults(try whole.decode(HostDefaults.self))
        case "host.styles":
            self = .outputStyles(try keyed.decodeIfPresent([String].self, forKey: .styles) ?? [])
        case "session.tasks":
            self = .sessionTasks(
                key: try keyed.decode(String.self, forKey: .key),
                tasks: try keyed.decodeIfPresent([HostTask].self, forKey: .tasks) ?? []
            )
        case "ask":
            self = .ask(try whole.decode(HostAsk.self))
        case "ask.withdrawn":
            self = .askWithdrawn(
                askId: try keyed.decode(String.self, forKey: .askId),
                key: try keyed.decode(String.self, forKey: .key)
            )
        case "session.result":
            self = .sessionResult(try whole.decode(HostSessionResult.self))
        case "session.exit":
            self = .sessionExit(
                key: try keyed.decode(String.self, forKey: .key),
                reason: try keyed.decode(String.self, forKey: .reason)
            )
        default:
            self = .unrecognised(type: type)
        }
    }
}

// MARK: - Requests

/// A question's answer: one label, or several where the question allowed it.
public enum HostAnswerValue: Encodable, Hashable, Sendable {
    case one(String)
    case many([String])

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .one(let value): try container.encode(value)
        case .many(let values): try container.encode(values)
        }
    }
}

public enum HostRequest: Encodable, Hashable, Sendable {
    /// `launches` is whether `launch` events should come here: an app on the
    /// host's own Mac.
    case hello(
        id: String, launches: Bool = false
    )
    /// The answer to a `launch`: the started session's key, or why not.
    case launched(id: String, launchId: String, key: String? = nil, error: String? = nil)
    case start(
        id: String,
        cwd: String,
        prompt: String,
        model: String? = nil,
        permissionMode: String? = nil,
        name: String? = nil,
        /// How the session writes. Sent here or never — there is no request on
        /// this wire to move one, which since CLI v2.1.278 is the app's choice
        /// and not the SDK's: `applyFlagSettings` would move it, and the app
        /// keeps one app-wide pick bound at launch instead.
        outputStyle: String? = nil,
        /// How hard it thinks. Unlike the style this one moves, so the same
        /// name is a request of its own below.
        effort: String? = nil,
        /// The transcript to pick up rather than begin. A resumed session keeps
        /// that id, so the row stays bound to the file it was already bound to.
        resume: String? = nil,
        /// The key to file it under. Rows are named by this, so a resumed
        /// conversation handed a fresh one would arrive in the list as a
        /// stranger rather than as the row it was.
        key: String? = nil,
        origin: SessionOrigin? = nil,
        /// The session's only credential, which outranks the CLI's stored
        /// login. Nil leaves it on that login.
        apiKey: String? = nil
    )
    case send(id: String, key: String, text: String)
    /// Answers key on the question's own text, which is what the host echoes back
    /// to the SDK, and so do the notes written beside them.
    ///
    /// A `response` is not a fuller answer but a different one: the CLI reads it
    /// as what was said *instead* of picking, and the result it writes carries
    /// nothing else — so anything sent in `answers` beside one is dropped, and
    /// the two are never sent together.
    case answerQuestion(
        id: String,
        askId: String,
        answers: [String: HostAnswerValue],
        notes: [String: String] = [:],
        response: String? = nil
    )
    case answerPermission(
        id: String,
        askId: String,
        optionId: String,
        message: String? = nil
    )
    case mode(id: String, key: String, permissionMode: String)
    /// Asks what Default resolves to for a directory. Named by folder rather
    /// than by session because the pickers ask before anything is running.
    case resolveDefaults(id: String, cwd: String)
    /// Moves a running session's effort, from its next turn on. The dial's
    /// half; the style beside it in the composer has no equivalent.
    case effort(id: String, key: String, effort: String)
    case interrupt(id: String, key: String)
    case stop(id: String, key: String)
    /// Ends one agent and leaves the session working. `interrupt` is the blunt
    /// version: it ends the whole turn, and any agent the turn was waiting on
    /// goes with it.
    case stopTask(id: String, key: String, taskId: String)
    case mcpReconnect(id: String, key: String, server: String)
    case mcpLogin(id: String, key: String, server: String)
    /// By transcript id, since the session needn't be one the host is running.
    case rename(id: String, sessionId: String, title: String)
    /// The CLI's `/btw`: answered off the live conversation without tools, and
    /// never written to the transcript or heard by later turns. `history` is the
    /// aside so far, which the CLI doesn't keep.
    case side(id: String, key: String, question: String, history: [SideExchange])

    public var id: String {
        switch self {
        case .send(let id, _, _), .mode(let id, _, _),
            .effort(let id, _, _), .resolveDefaults(let id, _),
            .interrupt(let id, _), .stop(let id, _), .stopTask(let id, _, _), .rename(let id, _, _),
            .mcpReconnect(let id, _, _), .mcpLogin(let id, _, _):
            id
        case .hello(
            let id, _
        ): id
        case .start(
            let id, _, _, _, _, _, _, _, _, _, _, _
        ): id
        case .launched(let id, _, _, _): id
        case .answerQuestion(let id, _, _, _, _): id
        case .answerPermission(let id, _, _, _): id
        case .side(let id, _, _, _): id
        }
    }

    private enum Key: String, CodingKey {
        case id, type, cwd, prompt, model, permissionMode, name
        case outputStyle, effort
        case resume, key, text, taskId
        case askId, kind, answers, annotations, response, optionId, message
        case sessionId, title, question, history
        case launches, launchId, error, origin, server, apiKey
        case protocolVersion = "protocol"
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(id, forKey: .id)

        switch self {
        case .hello(
            _, let launches
        ):
            try container.encode("hello", forKey: .type)
            try container.encode(HostProtocol.version, forKey: .protocolVersion)
            if launches { try container.encode(true, forKey: .launches) }

        case .launched(_, let launchId, let key, let error):
            try container.encode("launched", forKey: .type)
            try container.encode(launchId, forKey: .launchId)
            try container.encodeIfPresent(key, forKey: .key)
            try container.encodeIfPresent(error, forKey: .error)

        case .start(
            _, let cwd, let prompt, let model, let permissionMode, let name,
            let outputStyle, let effort, let resume, let key,
            let origin, let apiKey
        ):
            try container.encode("start", forKey: .type)
            try container.encode(cwd, forKey: .cwd)
            try container.encode(prompt, forKey: .prompt)
            try container.encodeIfPresent(model, forKey: .model)
            try container.encodeIfPresent(permissionMode, forKey: .permissionMode)
            try container.encodeIfPresent(name, forKey: .name)
            try container.encodeIfPresent(outputStyle, forKey: .outputStyle)
            try container.encodeIfPresent(effort, forKey: .effort)
            try container.encodeIfPresent(resume, forKey: .resume)
            try container.encodeIfPresent(key, forKey: .key)
            try container.encodeIfPresent(origin, forKey: .origin)
            try container.encodeIfPresent(apiKey, forKey: .apiKey)

        case .send(_, let key, let text):
            try container.encode("send", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(text, forKey: .text)

        case .answerQuestion(_, let askId, let answers, let notes, let response):
            try container.encode("answer", forKey: .type)
            try container.encode(askId, forKey: .askId)
            try container.encode("question", forKey: .kind)
            try container.encode(answers, forKey: .answers)
            if !notes.isEmpty {
                try container.encode(notes.mapValues { ["notes": $0] }, forKey: .annotations)
            }
            try container.encodeIfPresent(response, forKey: .response)

        case .answerPermission(_, let askId, let optionId, let message):
            try container.encode("answer", forKey: .type)
            try container.encode(askId, forKey: .askId)
            try container.encode("permission", forKey: .kind)
            try container.encode(optionId, forKey: .optionId)
            try container.encodeIfPresent(message, forKey: .message)

        case .mode(_, let key, let permissionMode):
            try container.encode("mode", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(permissionMode, forKey: .permissionMode)

        case .effort(_, let key, let effort):
            try container.encode("effort", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(effort, forKey: .effort)

        case .resolveDefaults(_, let cwd):
            try container.encode("defaults", forKey: .type)
            try container.encode(cwd, forKey: .cwd)

        case .interrupt(_, let key):
            try container.encode("interrupt", forKey: .type)
            try container.encode(key, forKey: .key)

        case .stop(_, let key):
            try container.encode("stop", forKey: .type)
            try container.encode(key, forKey: .key)

        case .stopTask(_, let key, let taskId):
            try container.encode("stopTask", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(taskId, forKey: .taskId)

        case .mcpReconnect(_, let key, let server):
            try container.encode("mcpReconnect", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(server, forKey: .server)

        case .mcpLogin(_, let key, let server):
            try container.encode("mcpLogin", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(server, forKey: .server)

        case .rename(_, let sessionId, let title):
            try container.encode("rename", forKey: .type)
            try container.encode(sessionId, forKey: .sessionId)
            try container.encode(title, forKey: .title)

        case .side(_, let key, let question, let history):
            try container.encode("side", forKey: .type)
            try container.encode(key, forKey: .key)
            try container.encode(question, forKey: .question)
            if !history.isEmpty { try container.encode(history, forKey: .history) }

        }
    }

    /// One request, framed the way the host reads them.
    public func line() throws -> Data {
        var data = try JSONEncoder().encode(self)
        data.append(0x0A)
        return data
    }
}
