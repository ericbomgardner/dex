import Foundation

public struct AgentSession: Hashable, Sendable {

    /// What a session is called before the CLI has named it, about a second in.
    /// Its folder used to stand in, which the row already says twice over — on
    /// the qualifier line and again under the path — and which is the one thing
    /// about a new session you chose yourself and so already know.
    public static let unnamed = "New session"

    public let cwd: String

    public let startedAt: Double

    /// What the host last said the session is doing. A row the archive kept is
    /// `idle` with no host behind it, which is what the host would say of it.
    public let state: HostSessionState

    /// The pid of the host holding the session, or nil for a row only the
    /// archive remembers. A hosted session has no process of its own.
    public let hostPID: Int?

    public let sessionId: String?

    public let name: String?

    /// The host's own key for the session, which is `rowID`: it exists before
    /// the transcript id does, so without it the row's identity would change
    /// under everything keyed on it the moment the transcript arrived.
    public let hostKey: String

    public init(
        cwd: String,
        startedAt: Double,
        hostKey: String,
        state: HostSessionState,
        hostPID: Int? = nil,
        sessionId: String? = nil,
        name: String? = nil
    ) {
        self.cwd = cwd
        self.startedAt = startedAt
        self.hostKey = hostKey
        self.state = state
        self.hostPID = hostPID
        self.sessionId = sessionId
        self.name = name
    }
}

extension AgentSession {

    /// Whether a host is holding the session, rather than only the archive.
    public var isLive: Bool { hostPID != nil }

    /// Whether anything is still there to write a result into this session's
    /// transcript, which is what tells a call still running from one left
    /// hanging by a death. Since CLI v2.1.236 the file says nothing either way:
    /// a killed session writes no interruption record, so its last call simply
    /// stays pending forever.
    ///
    /// Not `isLive` alone. `hostPID` is set for every row the host reports —
    /// including one whose own CLI died while the host stayed up, which is
    /// exactly the row this has to answer `false` for.
    public var canAnswer: Bool {
        isLive && state != .failed
    }

    public var startedAtDate: Date {
        Date(timeIntervalSince1970: startedAt / 1000)
    }

    public var rowID: String { hostKey }

    public var displayName: String {
        if let name, !name.isEmpty { return name }
        return AgentSession.unnamed
    }

    /// The name the CLI gave the session, or nothing. `displayName` answers the
    /// placeholder where there is none, which is only safe somewhere the folder
    /// is already on screen beside it.
    public var chosenName: String? {
        guard let name, !name.isEmpty else { return nil }
        return name
    }

    /// The folder the session is running in. What to call it where nothing else
    /// says which session it is — a notification is one line, and every session
    /// the CLI hasn't named yet would otherwise announce itself as the same one.
    public var folderName: String {
        let leaf = URL(fileURLWithPath: cwd).lastPathComponent
        return leaf.isEmpty ? cwd : leaf
    }

    /// The same session under the name its transcript has since given it. A
    /// row's name is fixed when the row is built, and the file is read again
    /// between builds — on every write to it — so without this the name would
    /// wait for whatever the host said next.
    public func named(_ name: String) -> AgentSession {
        AgentSession(
            cwd: cwd,
            startedAt: startedAt,
            hostKey: hostKey,
            state: state,
            hostPID: hostPID,
            sessionId: sessionId,
            name: name
        )
    }

    public var isAsking: Bool { state == .asking }

    /// The turn is over: the host has the session idle, done or failed. A state
    /// from a newer host is not, since guessing finished retires a live session.
    public var hasFinishedWorking: Bool {
        switch state {
        case .idle, .done, .failed:
            return true
        case .starting, .running, .compacting, .asking, .unknown:
            return false
        }
    }

    /// The word the row's tooltip and the fleet file use for the state. Older
    /// than the host's vocabulary, and `list_sessions` prints it, so it stays.
    public var stateWord: String {
        switch state {
        case .starting, .running, .compacting, .unknown: "working"
        case .asking: "blocked"
        case .idle: "stopped"
        case .done: "done"
        case .failed: "failed"
        }
    }
}
