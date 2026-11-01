import Foundation

/// A session that has been let onto the pointer or keyboard, until its turn
/// ends or it stops driving.
public struct ScreenTakeover: Equatable, Sendable {
    public let key: String
    public let since: Date
    /// When the newest driving command was let through.
    public let lastDrove: Date
    /// That command whole, to find its call in the transcript by.
    public let command: String?
    /// The command that was allowed, cut to a line, for the bar to name.
    public let doing: String?

    public init(key: String, since: Date, lastDrove: Date? = nil, command: String? = nil, doing: String?) {
        self.key = key
        self.since = since
        self.lastDrove = lastDrove ?? since
        self.command = command
        self.doing = doing
    }
}

/// Whether a takeover is let through on its own or put to the user.
///
/// A session asks to drive the screen the way it asks anything else, but the
/// answer depends on something no ask carries: whether anyone is at the
/// keyboard. Away from it, the pointer is nobody's and the session gets it,
/// with the bar and a notification saying so. At it, the ask stands and the
/// card takes over. Once let through, the rest of the same turn goes without
/// asking again — six clicks in a turn were six asks otherwise, and the bar is
/// already up for all of them.
public enum ScreenTakeoverPolicy {

    /// How long the pointer and keyboard have to have been still before the
    /// session takes them without asking. Long enough that reading a page
    /// doesn't count as gone; short enough that a session waits on a walk to
    /// the kettle rather than the whole of it.
    public static let idleAfter: TimeInterval = 30

    /// How long after its last driving command a session keeps the screen. A
    /// turn that clicked through a check and went on to other work held the
    /// bar up until the turn ended, and Stop was the only way to take it down.
    public static let lapseAfter: TimeInterval = 60

    public enum Decision: Equatable, Sendable {
        case allow
        case ask
    }

    public static func decide(
        idleFor: TimeInterval,
        alreadyDriving: Bool,
        idleAfter: TimeInterval = idleAfter
    ) -> Decision {
        if alreadyDriving { return .allow }
        return idleFor >= idleAfter ? .allow : .ask
    }

    /// Whether the session has let go of the screen without its turn ending:
    /// the newest drive came back at least `lapseAfter` ago and nothing of it
    /// is still running. A result from before the drive was allowed is an
    /// earlier run of the same command, not this one.
    public static func hasLapsed(
        _ takeover: ScreenTakeover,
        returnedAt: Date?,
        stillRunning: Bool,
        now: Date,
        lapseAfter: TimeInterval = lapseAfter
    ) -> Bool {
        guard let returnedAt, returnedAt > takeover.lastDrove, !stillRunning else { return false }
        return now.timeIntervalSince(returnedAt) >= lapseAfter
    }

    /// Whether this state ends the turn the takeover was granted for. Listed
    /// rather than "anything but running": a state the host adds should keep
    /// the bar up rather than take it down, since the bar is what says the
    /// session still has the machine. An idle session whose drive is still a
    /// running task, a Monitor watching or a backgrounded Bash, keeps driving
    /// past its turn's result, so the bar stays until the lapse takes it down.
    public static func endsTakeover(_ state: HostSessionState, driveStillRunning: Bool = false) -> Bool {
        switch state {
        case .idle: !driveStillRunning
        case .done, .failed: true
        default: false
        }
    }
}

/// The Bash and Monitor calls in a transcript and when each came back, read as
/// the file grows. The ask names a command and not a call, so a drive is found
/// by its command: the newest call running it.
public struct DriveReturns: Sendable {
    private var calls: [String: String] = [:]
    private var returned: [String: Date] = [:]

    public init() {}

    public mutating func read(_ lines: [Data]) {
        for line in lines {
            guard let record = TranscriptRecord.decode(line) else { continue }
            for block in record.message?.content ?? [] {
                switch block {
                case .toolUse(let id, let name, let input) where name == "Bash" || name == "Monitor":
                    if let command = input.objectValue?["command"]?.stringValue {
                        calls[command] = id
                    }
                case .toolResult(let id, _, _):
                    if let at = record.at { returned[id] = at }
                default:
                    continue
                }
            }
        }
    }

    /// The newest call running `command`, and when it came back if it has.
    public func call(running command: String) -> (id: String, returnedAt: Date?)? {
        guard let id = calls[command] else { return nil }
        return (id, returned[id])
    }
}
