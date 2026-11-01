import Foundation

/// The list's rows, made from what the host says about a session and what the
/// archive kept of one it no longer holds. Two fields that look like details
/// are not: a row without `hostPID` is never watched for transcript activity,
/// and a row whose `lastUpdatedAt` cannot move sorts to the bottom and stays
/// resolved once resolved.
extension AgentSession {

    public init(
        hosted summary: HostSessionSummary,
        hostPID: Int,
        title: String? = nil
    ) {
        self.init(
            cwd: summary.cwd,
            startedAt: HostTimestamp.epochMilliseconds(summary.startedAt),
            hostKey: summary.key,
            state: summary.state,
            hostPID: hostPID,
            sessionId: summary.sessionId,
            // The transcript's title outranks the host's, which is only ever a
            // name chosen at dispatch. Nameless either way is not a fallback to
            // the folder: the row wears its placeholder until the CLI has named
            // the session, about a second in, and this is the field a rename
            // comes back on.
            name: title ?? summary.name
        )
    }

    /// Deliberately without a host pid: there is no host to answer and no file
    /// being written, and a row carrying one is a row the transcript watcher
    /// tails for changes that cannot come. Idle rather than done, too — the
    /// difference between a session that ended and one that is merely not
    /// running just now, and the second is what this is.
    public init(archived entry: HostedArchive.Entry) {
        self.init(
            cwd: entry.cwd,
            startedAt: HostTimestamp.epochMilliseconds(entry.startedAt),
            hostKey: entry.key,
            state: .idle,
            hostPID: nil,
            sessionId: entry.sessionId,
            name: entry.name
        )
    }
}

extension SessionRowModel {

    public init(
        hosted summary: HostSessionSummary,
        hostPID: Int,
        worktree: WorktreeOrigin? = nil,
        lastEventAt: Date? = nil,
        digest: SessionDigest = SessionDigest(),
        ask: HostAsk? = nil,
        runningTasks: Int = 0
    ) {
        self.init(
            session: AgentSession(
                hosted: summary, hostPID: hostPID, title: digest.title
            ),
            worktree: worktree,
            // Nothing else moves the row's clock: left alone it would freeze at
            // its start time, sort to the bottom, and stay settled once
            // settled.
            pinnedUpdate: lastEventAt,
            livePermissionMode: summary.permissionMode,
            owesTurn: summary.state == .asking,
            hostedSummary: Self.hostedSummary(state: summary.state, ask: ask, digest: digest),
            context: digest.context,
            runningTasks: runningTasks,
            origin: summary.origin,
            mcpServers: summary.mcpServers,
            mcpCalls: digest.mcpCalls ?? [:]
        )
    }

    /// A row for a session the host is no longer running.
    public init(archived entry: HostedArchive.Entry, worktree: WorktreeOrigin? = nil) {
        self.init(
            session: AgentSession(archived: entry),
            worktree: worktree,
            pinnedUpdate: entry.lastActivityAt,
            livePermissionMode: entry.permissionMode,
            owesTurn: false,
            hostedSummary: entry.lastMessage,
            context: entry.context,
            origin: entry.origin
        )
    }

    /// The line under a hosted row's title. A session holding something out for
    /// you says that first: the ask is the one thing on the row you can act on,
    /// it is already on the socket, and the message behind it is the message that
    /// prompted the ask anyway.
    ///
    /// Only while it is still asking, though. Withdrawing an ask and moving off
    /// `asking` are two messages from the host rather than one, so a row that
    /// trusted the queue alone would keep holding out an answered question for
    /// however long the other message took to arrive.
    static func hostedSummary(
        state: HostSessionState,
        ask: HostAsk?,
        digest: SessionDigest
    ) -> String? {
        if state == .asking, let ask { return line(for: ask) }
        if state == .compacting { return "Compacting…" }
        return digest.lastMessage
    }

    static func line(for ask: HostAsk) -> String {
        switch HostAskContent.read(ask) {
        case .questions(let questions):
            // A question the app can't read is still a question; naming the tool
            // beats a row that says nothing while the session waits.
            return questions.first?.question ?? ask.toolName
        case .permission(let request):
            guard let summary = request.summary else { return request.toolName }
            return "\(request.toolName): \(summary)"
        }
    }
}

public enum HostTimestamp {

    /// The list keeps start times as epoch milliseconds; the host writes ISO
    /// 8601. Getting the unit wrong dates every hosted row to 1970.
    static func epochMilliseconds(_ iso: String) -> Double {
        guard let date = date(iso) else { return Date().timeIntervalSince1970 * 1000 }
        return date.timeIntervalSince1970 * 1000
    }

    public static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}
