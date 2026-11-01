import Foundation

public struct SessionRowModel: Sendable, Hashable {

    public private(set) var session: AgentSession

    public private(set) var lastActivityAt: Date?

    public private(set) var worktree: WorktreeOrigin?

    public private(set) var mergeStatus: WorktreeMergeStatus?

    public private(set) var lastUpdatedAt: Date

    public private(set) var pinnedUpdate: Date?

    /// The mode the session is running in now, off the socket.
    public private(set) var livePermissionMode: String?

    /// Whether the transcript ends on something the session hasn't answered.
    /// Only asked of a session with a process, whose file is still being written
    /// to; a stopped session's dangling turn is one nobody is working on.
    public private(set) var owesTurn: Bool

    /// The whole of the row's second line, resolved before the row was built.
    public private(set) var hostedSummary: String?

    /// What the session is carrying, and so what its next turn costs.
    public private(set) var context: SessionContext?

    /// Background work the host still holds for the session — agents and shell
    /// commands launched with run_in_background, off `session.tasks`. The turn
    /// that launched one ends at its receipt, so nothing in the transcript says
    /// the session is still waiting; this count is the only thing that does.
    public private(set) var runningTasks: Int

    /// The background watcher that started it, if one did.
    public private(set) var origin: SessionOrigin?

    /// The host's startup reading of the session's MCP servers.
    public private(set) var mcpServers: [HostMcpServer]?

    /// How the newest call to each MCP server went, off the transcript.
    public private(set) var mcpCalls: [String: McpCallOutcome]

    public func mcpTrouble(reconnected: [String: Date] = [:]) -> [McpTrouble] {
        McpTrouble.of(
            servers: mcpServers, calls: mcpCalls, since: session.startedAtDate, reconnected: reconnected
        )
    }

    public init(
        session: AgentSession,
        worktree: WorktreeOrigin? = nil,
        lastActivityAt: Date? = nil,
        mergeStatus: WorktreeMergeStatus? = nil,
        pinnedUpdate: Date? = nil,
        livePermissionMode: String? = nil,
        owesTurn: Bool = false,
        hostedSummary: String? = nil,
        context: SessionContext? = nil,
        runningTasks: Int = 0,
        origin: SessionOrigin? = nil,
        mcpServers: [HostMcpServer]? = nil,
        mcpCalls: [String: McpCallOutcome] = [:]
    ) {
        self.origin = origin
        self.mcpServers = mcpServers
        self.mcpCalls = mcpCalls
        self.hostedSummary = hostedSummary
        self.context = context
        self.runningTasks = runningTasks
        self.session = session
        self.worktree = worktree
        self.lastActivityAt = lastActivityAt
        self.mergeStatus = mergeStatus
        self.pinnedUpdate = pinnedUpdate
        self.livePermissionMode = livePermissionMode
        self.owesTurn = owesTurn
        self.lastUpdatedAt = pinnedUpdate ?? session.startedAtDate
    }

    public var rowID: String { session.rowID }

    /// The host's word that the CLI is summarising the conversation. Nothing is
    /// written to the transcript while it runs, so the file-write clock reads
    /// the session as quiet from 15s in; this is what keeps the spinner on for
    /// the other thirty.
    public var isCompacting: Bool { session.state == .compacting }
    public var isAsking: Bool { session.isAsking }

    public func activity(now: Date = Date()) -> Activity {
        ActivitySignal.resolve(
            state: session.state,
            lastTranscriptWrite: lastActivityAt,
            now: now
        )
    }

    /// Whether the session has a turn to finish. Two answers rather than one:
    /// the host's record of it, and the end of its transcript, which is written
    /// as you send rather than when the session gets around to saying what it is
    /// doing. The transcript is only ever heard where the record says the session
    /// has stopped, which is the one thing it is late about.
    public var isWorking: Bool {
        switch session.state {
        // A state from a newer host is read as work rather than as finished.
        case .starting, .running, .compacting, .unknown:
            return true

        case .idle, .done, .failed:
            return owesTurn || runningTasks > 0

        // Asking is the record's alone: a question is a call nothing has come
        // back to, so the file reads the same whether the session is working on
        // one or holding it out for you.
        case .asking:
            return false
        }
    }

    /// The turn is over and background work the host holds is what's left. The
    /// transcript goes quiet for as long as it runs — that's what backgrounding
    /// is — so the file-write clock below cannot answer for this stretch, and
    /// the task set off the socket stands in as the liveness reading.
    ///
    /// An owed turn outranks it: a message sent while the work is out is a real
    /// turn again, with a think to interrupt and a transcript clock measuring
    /// it, and reading that stretch as only-waiting took the Stop button off
    /// exactly where it belongs.
    public var isAwaitingBackgroundWork: Bool {
        switch session.state {
        case .idle, .done, .failed:
            return runningTasks > 0 && !owesTurn
        case .starting, .running, .compacting, .asking, .unknown:
            return false
        }
    }

    public func isIdleWhileWorking(now: Date = Date()) -> Bool {
        isWorking && !isAwaitingBackgroundWork && !isCompacting && activity(now: now).isQuiet
    }

    public func isActivelyWorking(now: Date = Date()) -> Bool {
        isWorking && (isAwaitingBackgroundWork || isCompacting || activity(now: now) == .active)
    }

    public func refreshed(
        activityAt date: Date?,
        pinnedUpdate pin: Date? = nil,
        owesTurn owed: Bool? = nil,
        title: String? = nil,
        hostedSummary line: String? = nil,
        context carried: SessionContext? = nil,
        mcpCalls calls: [String: McpCallOutcome]? = nil
    ) -> SessionRowModel {
        var row = self
        if let title { row.session = session.named(title) }
        row.lastActivityAt = date ?? lastActivityAt
        row.pinnedUpdate = pin ?? pinnedUpdate
        row.owesTurn = owed ?? owesTurn
        row.hostedSummary = line ?? hostedSummary
        row.context = carried ?? context
        row.mcpCalls = calls ?? mcpCalls
        row.lastUpdatedAt = row.pinnedUpdate ?? row.session.startedAtDate
        return row
    }

    public func withOrigin(_ origin: SessionOrigin?) -> SessionRowModel {
        var row = self
        row.origin = origin
        return row
    }

    public func withMergeStatus(_ status: WorktreeMergeStatus?) -> SessionRowModel {
        var row = self
        row.mergeStatus = status
        return row
    }

    public var summary: String {
        if let hostedSummary, !hostedSummary.isEmpty {
            return hostedSummary
        }
        if session.isAsking {
            return "waiting: permission prompt"
        }
        return Format.shortPath(session.cwd)
    }
}

extension SessionRowModel {

    public var startedAt: Date { session.startedAtDate }

    public var projectPath: String { worktree?.path ?? session.cwd }

    public var worktreeBranch: String? {
        guard let branch = worktree?.branch, !branch.isEmpty else { return nil }
        return branch
    }

    public var worktreePath: String? {
        worktree != nil ? session.cwd : nil
    }
}
