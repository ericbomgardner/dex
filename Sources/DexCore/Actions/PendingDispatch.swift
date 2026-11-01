import Foundation

public struct PendingDispatch: Identifiable, Sendable, Hashable {
    public let id: UUID

    public let prompt: String

    public let project: String
    public let startedAt: Date

    public var rowID: String?

    public let knownRowIDs: Set<String>

    public init(
        id: UUID = UUID(),
        prompt: String,
        project: String,
        startedAt: Date = Date(),
        rowID: String? = nil,
        knownRowIDs: Set<String>
    ) {
        self.id = id
        self.prompt = prompt
        self.project = project
        self.startedAt = startedAt
        self.rowID = rowID
        self.knownRowIDs = knownRowIDs
    }

    public func matchingRow(in rows: [SessionRowModel]) -> SessionRowModel? {
        if let rowID {
            return rows.first { $0.rowID == rowID }
        }
        return rows.first { !knownRowIDs.contains($0.rowID) && $0.projectPath == project }
    }

    /// The placeholder the row it becomes will be wearing, rather than a name of
    /// its own: the two are on screen one after the other, and a title that
    /// changed as the session arrived would read as something having happened.
    public var title: String { AgentSession.unnamed }

    /// What was typed, folded the way the file's own second line is folded, so
    /// the line doesn't reflow when the transcript starts answering for it.
    public var opening: String? { SessionDigestReader.oneLine(prompt) }

    public static let patience: TimeInterval = 20

    public func hasExpired(now: Date = Date()) -> Bool {
        now.timeIntervalSince(startedAt) >= Self.patience
    }
}
