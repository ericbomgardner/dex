import Foundation

/// What the dashboard can see, in the shape a sibling agent can read. The app
/// has already merged the host's session list and the git layout into rows;
/// this is that merge, written down, so a session can answer "who else is in
/// this repo" without reassembling it itself.
public struct FleetSnapshot: Encodable, Sendable, Equatable {

    /// When the fleet last *changed*, not when the file was last considered.
    public let updatedAt: String

    public let sessions: [FleetSession]

    public init(rows: [SessionRowModel], updatedAt: Date) {
        self.updatedAt = FleetTimestamp.string(from: updatedAt)
        self.sessions = SessionOrdering.sorted(rows).map(FleetSession.init)
    }

    private init(updatedAt: String, sessions: [FleetSession]) {
        self.updatedAt = updatedAt
        self.sessions = sessions
    }

    /// The same fleet with each session's messaging name filled in from the
    /// CLI's registry, keyed by session id, and its folder and branch moved to
    /// wherever the registry says it is now. A session the registry doesn't
    /// hold keeps no address, which is what a session that isn't running reads.
    public func addressed(
        by entries: [String: SessionRegistry.Entry],
        worktree: (String) -> WorktreeOrigin? = WorktreeIndex.resolve
    ) -> FleetSnapshot {
        FleetSnapshot(
            updatedAt: updatedAt,
            sessions: sessions.map { session in
                session.addressed(session.sessionId.flatMap { entries[$0] }, worktree: worktree)
            }
        )
    }
}

public struct FleetSession: Encodable, Sendable, Equatable {

    /// The transcript UUID, for finding what this session actually did.
    public let sessionId: String?

    /// The transcript's title — a label, not an address.
    public let name: String

    /// The name another session messages this one by (`SendMessage`'s `to`),
    /// off the CLI's own registry. Nil for a session the CLI isn't holding.
    public private(set) var address: String?

    public let kind: String

    public let state: String
    public let running: Bool
    public let waitingFor: String?

    /// The one line the dashboard shows for this row.
    public let doing: String

    /// Where the agent is working — a worktree, when it has one.
    public private(set) var cwd: String

    /// The repository the work lands in, which is what two sessions collide over.
    public private(set) var repository: String
    public private(set) var branch: String?

    public let merge: FleetMerge?

    /// The background watcher that started it, if one did.
    public let origin: SessionOrigin?

    public let startedAt: String
    public let updatedAt: String

    init(_ row: SessionRowModel) {
        sessionId = row.session.sessionId
        name = row.session.displayName
        // `kind` and `waitingFor` are what `claude agents --json` said, which
        // the fleet file still says for whatever reads it.
        kind = "interactive"
        state = row.session.stateWord
        running = row.session.isLive
        waitingFor = row.session.isAsking ? "permission prompt" : nil
        doing = row.summary
        cwd = row.session.cwd
        repository = row.projectPath
        branch = row.worktreeBranch
        merge = row.mergeStatus.map(FleetMerge.init)
        origin = row.origin
        startedAt = FleetTimestamp.string(from: row.startedAt)
        updatedAt = FleetTimestamp.string(from: row.lastUpdatedAt)
    }

    func addressed(
        _ entry: SessionRegistry.Entry?,
        worktree: (String) -> WorktreeOrigin?
    ) -> FleetSession {
        var session = self
        session.address = entry?.address
        if let moved = entry?.cwd, moved != cwd {
            let origin = worktree(moved)
            session.cwd = moved
            session.repository = origin?.path ?? repository
            session.branch = origin?.branch
        }
        return session
    }
}

/// Whether this session's work has actually landed, which is the part a
/// sibling deciding to merge needs and can't see from its own worktree.
public struct FleetMerge: Encodable, Sendable, Equatable {
    public let base: String
    public let state: String
    public let unmergedCommits: Int?
    public let uncommittedFiles: Int?
    public let summary: String

    init(_ status: WorktreeMergeStatus) {
        base = status.base
        summary = status.mergeLabel
        uncommittedFiles = status.uncommittedFiles
        switch status.merge {
        case .merged:
            state = "merged"
            unmergedCommits = 0
        case .outstanding(let commits):
            state = "outstanding"
            unmergedCommits = commits
        case .branchGone:
            state = "branchGone"
            unmergedCommits = nil
        }
    }
}

enum FleetTimestamp {

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
}
