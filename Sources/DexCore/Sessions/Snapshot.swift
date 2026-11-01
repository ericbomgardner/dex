import Foundation

public struct Snapshot: Sendable {
    public var rows: [SessionRowModel]
    public var fetchedAt: Date?

    public var activityCheckedAt: Date?

    public init(
        rows: [SessionRowModel] = [],
        fetchedAt: Date? = nil,
        activityCheckedAt: Date? = nil
    ) {
        self.rows = rows
        self.fetchedAt = fetchedAt
        self.activityCheckedAt = activityCheckedAt
    }

    public var hasNeverLoaded: Bool { fetchedAt == nil }
}

public enum PollPolicy {

    public static let reconcileInterval: TimeInterval = 30
}
