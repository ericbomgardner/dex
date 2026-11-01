import Foundation

/// What the host has told us, folded into the state a list and a card need.
///
/// Kept apart from the socket and from SwiftUI so the interesting part — what a
/// given event does to what is on screen — can be tested without either.
public struct HostSessionIndex: Equatable, Sendable {

    public private(set) var sessions: [String: HostSessionSummary] = [:]
    public private(set) var asks = HostAskQueue()

    /// The host's pid, which stands in for each session's own — they have none.
    public private(set) var hostPID: Int?

    /// The modes the host will take on a `mode` request, off its welcome. The
    /// host outlives the app and is never rebuilt with it, so this is the only
    /// thing that says which of them the process now holding the socket has
    /// actually heard of — one from before a mode was added refuses it by name.
    public private(set) var acceptedModes: [String] = []

    /// The efforts it will take on an `effort` request, off the same welcome and
    /// for the same reason. A host from before this existed sends none, and
    /// empty means offer everything rather than offer nothing.
    public private(set) var acceptedEfforts: [String] = []

    /// Every output style the CLI has, as the newest session found them. Unlike
    /// the two lists above it does not arrive with the welcome on a host that
    /// has yet to run a session — the list lives on a running session's
    /// `initializationResult()` and nowhere else — so it is replaced only when
    /// something says otherwise, never emptied by a host that had nothing to
    /// say.
    public private(set) var outputStyles: [String] = []

    /// What Default resolves to, per directory. Kept by folder because the
    /// answer is a merge and a project may hold settings of its own, so the
    /// composer pointed at two projects has two of these.
    ///
    /// Not cleared with the host. It describes files on disk rather than
    /// anything the host is holding, and a picker that forgets what Default
    /// means every time the socket blinks is a picker that goes back to saying
    /// the bare word.
    public private(set) var defaults: [String: HostDefaults] = [:]

    /// What the process holding the socket is running, against what the bundle
    /// beside it holds. Off the welcome for the same reason the modes are: the
    /// host outlives the app, and this is the only word for which build it began
    /// under.
    public private(set) var sdk: HostSDK?

    /// The commit the host's bundle was built from, off the welcome. Nil is a
    /// host too old to say or one run from a checkout — not one that matches.
    public private(set) var hostBuild: String?

    /// Whether the host says it is holding work, off the welcome. Nil is a host
    /// too old to answer, which never reads as safe to stop.
    public private(set) var hostBusy: Bool?

    /// What the host serves beyond sessions, off its welcome. Empty from one
    /// too old to say, which serves none of it.
    public private(set) var capabilities: [String] = []

    /// The host's own `~/.claude`, off the welcome. Nil from a host too old
    /// to say.
    public private(set) var configDirectory: String?

    public var servesRename: Bool { capabilities.contains("rename") }

    public var servesSideQuestions: Bool { capabilities.contains("side") }

    public var servesMcpActions: Bool { capabilities.contains("mcp") }

    /// An older host takes a start's `apiKey` and drops it, leaving the session on the CLI's login.
    public var takesAPIKey: Bool { capabilities.contains("apiKey") }

    /// When the conversation last moved: turn edges, questions, and what we
    /// sent ourselves — `HostEvent.movesRowClock` says which events count,
    /// and `touched` is the send's own stamp. Off the socket there is
    /// nothing else to move a hosted row's clock, and a row whose clock
    /// never moves sinks in the sort and stays settled once settled.
    ///
    /// Live that is when we heard it; on connecting it is what the host
    /// says, which is a coarser clock — the host stamps its record on every
    /// emit, subagent bookends included — taken anyway because dating the
    /// welcome's sessions from the connection moves every hosted row's clock
    /// past every resolution made against it last run, so each launch brings
    /// back every hosted row you had dismissed.
    public private(set) var lastEventAt: [String: Date] = [:]

    /// What each session has running that will come back to it on its own — a
    /// background agent or shell command. Replaced wholesale each time the host
    /// speaks: it sends the set, not the changes.
    public private(set) var tasks: [String: [HostTask]] = [:]

    public init() {}

    /// Whether anything the app can see would be lost if the host went now,
    /// the app-side mirror of the host's own `busy`. Watchers count: ending
    /// one ends what the session was waiting on. A state this build doesn't
    /// know reads as work.
    public var holdsWork: Bool {
        if !asks.isEmpty { return true }
        if tasks.values.contains(where: { !$0.isEmpty }) { return true }
        return sessions.values.contains { session in
            switch session.state {
            case .idle, .done, .failed: false
            case .starting, .running, .compacting, .asking, .unknown: true
            }
        }
    }

    /// When any session last moved, by the row clock.
    public var lastMoved: Date? { lastEventAt.values.max() }

    /// The task a given call is still running, where the host has one. Nil means
    /// there is nothing to stop — an agent from before this app connected, one
    /// the host has already seen finish, or a session it never held.
    public func task(forKey key: String, toolUseID: String) -> HostTask? {
        tasks[key]?.first { $0.toolUseId == toolUseID }
    }

    public var ordered: [HostSessionSummary] {
        sessions.values.sorted {
            $0.startedAt == $1.startedAt ? $0.key < $1.key : $0.startedAt < $1.startedAt
        }
    }

    /// A hosted session is found by transcript id, since that is the only name
    /// it shares with the rest of the app.
    public func summary(sessionID: String) -> HostSessionSummary? {
        sessions.values.first { $0.sessionId == sessionID }
    }

    /// When a session was last busy, falling back to when it started: one the
    /// host has mentioned only once is dated by that rather than by now, which
    /// would date it from the moment we happened to ask.
    public func lastActivityAt(key: String, now: Date = Date()) -> Date {
        lastEventAt[key]
            ?? sessions[key].flatMap { HostTimestamp.date($0.startedAt) }
            ?? now
    }

    public mutating func apply(
        _ event: HostEvent,
        now: () -> String = Self.timestamp,
        heardAt: Date = Date()
    ) {
        if event.movesRowClock, let key = event.sessionKey { lastEventAt[key] = heardAt }

        switch event {
        case .welcome(let welcome):
            hostPID = welcome.pid
            acceptedModes = welcome.modes
            acceptedEfforts = welcome.efforts ?? []
            if let styles = welcome.outputStyles, !styles.isEmpty { outputStyles = styles }
            sdk = HostSDK(loaded: welcome.sdk, onDisk: welcome.sdkOnDisk)
            hostBuild = welcome.build
            hostBusy = welcome.busy
            capabilities = welcome.capabilities
            configDirectory = welcome.configDir
            for session in welcome.sessions {
                lastEventAt[session.key] =
                    session.lastActivityAt.flatMap(HostTimestamp.date) ?? heardAt
            }
            sessions = Dictionary(
                welcome.sessions.map { ($0.key, $0) },
                uniquingKeysWith: { _, later in later }
            )
            // A reconnecting app inherits the questions raised while nobody was
            // watching, which is most of the point of the host outliving it.
            asks.removeAll()
            for ask in welcome.pending { asks.received(ask) }

            // Dropped rather than kept: what a new connection is holding was
            // told to us by whatever process held the socket before, and the
            // `session.tasks` the host sends behind this welcome is the current
            // word. Kept, a task id from the old host would sit under a Stop
            // button that names something this one has never heard of.
            tasks.removeAll()

        case .sessionInit(let start):
            var summary =
                sessions[start.key]
                ?? HostSessionSummary(
                    key: start.key,
                    sessionId: nil,
                    cwd: start.cwd,
                    name: nil,
                    state: .running,
                    model: nil,
                    permissionMode: start.permissionMode,
                    startedAt: now()
                )
            summary.sessionId = start.sessionId
            summary.cwd = start.cwd
            summary.model = start.model
            summary.permissionMode = start.permissionMode
            summary.commands = start.commands ?? summary.commands
            summary.mcpServers = start.mcpServers ?? summary.mcpServers
            summary.outputStyle = start.outputStyle
            summary.effort = start.effort ?? summary.effort
            summary.name = start.name ?? summary.name
            summary.origin = start.origin ?? summary.origin
            sessions[start.key] = summary

        case .sessionStatus(let key, let state):
            sessions[key]?.state = state

        case .sessionMode(let key, let mode):
            sessions[key]?.permissionMode = mode

        case .sessionEffort(let key, let effort):
            sessions[key]?.effort = effort

        case .sessionMcp(let key, let servers):
            sessions[key]?.mcpServers = servers

        // Never emptied by a host that has nothing to say: an empty list is a
        // host that has not started a session, not a machine whose styles went
        // away, and a picker cleared by one would have no rows for the length
        // of a fresh host's first session.
        case .outputStyles(let styles):
            if !styles.isEmpty { outputStyles = styles }

        case .defaults(let resolved):
            defaults[resolved.cwd] = resolved

        // Replaced rather than merged, which is what makes a missed bookend
        // heal itself. A task the host can't name the call for is dropped: the
        // SDK registers ambient housekeeping without a tool call, so an unnamed
        // task is not the session's own work — counted, it would spin a row
        // with nothing in the transcript or the pane to explain it.
        case .sessionTasks(let key, let tasks):
            let named = tasks.filter { $0.toolUseId != nil }
            self.tasks[key] = named.isEmpty ? nil : named

        case .ask(let ask):
            asks.received(ask)

        case .askWithdrawn(let askId, _):
            asks.resolved(askId)

        case .sessionExit(let key, _):
            sessions.removeValue(forKey: key)
            asks.dropAll(forKey: key)
            lastEventAt.removeValue(forKey: key)
            tasks.removeValue(forKey: key)

        case .reply, .launch, .sessionResult, .unrecognised:
            break
        }
    }

    /// Answered locally rather than on the host's word: a card left standing
    /// until a round trip completes reads as one that didn't take the answer.
    public mutating func answered(_ askId: String) {
        asks.resolved(askId)
    }

    /// Stamped on the app's own word when a message leaves here: sent to a
    /// session mid-turn it is queued, and nothing comes back on the socket
    /// until the turn it is queued behind ends.
    public mutating func touched(key: String, at date: Date = Date()) {
        lastEventAt[key] = date
    }

    /// Moved on the app's word rather than the host's reply: a dial that waits
    /// for a round trip reads as one that didn't take the pick. There is no
    /// session word behind it to correct a refusal — nothing restates the
    /// effort the way a `system` message restates the mode — so a refused
    /// change is put back by the caller on the reply or not at all. Nil is
    /// what it goes back to when nobody had asked before: an absence rather
    /// than a level, which is why this takes one at all.
    public mutating func moved(toEffort effort: String?, forKey key: String) {
        sessions[key]?.effort = effort
    }

    public mutating func clear() {
        sessions.removeAll()
        asks.removeAll()
        lastEventAt.removeAll()
        tasks.removeAll()
        hostPID = nil
        acceptedModes = []
        acceptedEfforts = []
        sdk = nil
        capabilities = []
        configDirectory = nil
    }

    /// The rows the list should show for what the host is running. Empty until
    /// the welcome names a pid, since a row without one is never watched.
    public func rows(
        worktree: (String) -> WorktreeOrigin? = { _ in nil },
        digest: (HostSessionSummary) -> SessionDigest = { _ in SessionDigest() }
    ) -> [SessionRowModel] {
        guard let hostPID else { return [] }
        return ordered.map { summary in
            SessionRowModel(
                hosted: summary,
                hostPID: hostPID,
                worktree: worktree(summary.cwd),
                lastEventAt: lastEventAt[summary.key],
                digest: digest(summary),
                // The one the card is showing may be any of several parked on the
                // session; the row speaks for the session, so it takes the first.
                ask: asks.pending.first { $0.key == summary.key },
                // Watchers are kept in the set and out of the count: a monitor
                // outlives its turn by a quarter of an hour and settles by
                // nothing, so a row counting one spins for as long as it runs.
                runningTasks: tasks[summary.key]?.filter { !$0.isWatcher }.count ?? 0
            )
        }
    }

    public static func timestamp() -> String {
        ISO8601DateFormatter().string(from: Date())
    }
}
