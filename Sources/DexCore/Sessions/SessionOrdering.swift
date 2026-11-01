import Foundation

public enum SessionOrdering {

    private enum Bucket: Int {
        case blocked
        case working
        case failed
        case finished

        case settled
    }

    private static func bucket(
        _ row: SessionRowModel,
        resolutions: SessionResolutions
    ) -> Bucket {
        guard !resolutions.isSettled(row) else { return .settled }
        switch row.session.state {
        case .asking: return .blocked
        case .starting, .running, .compacting, .unknown: return .working
        case .failed: return .failed
        case .idle, .done: return .finished
        }
    }

    public static func sorted(
        _ rows: [SessionRowModel],
        resolutions: SessionResolutions = SessionResolutions()
    ) -> [SessionRowModel] {
        rows.sorted { lhs, rhs in
            let a = bucket(lhs, resolutions: resolutions)
            let b = bucket(rhs, resolutions: resolutions)
            if a != b { return a.rawValue < b.rawValue }
            if lhs.lastUpdatedAt != rhs.lastUpdatedAt {
                return lhs.lastUpdatedAt > rhs.lastUpdatedAt
            }
            return lhs.rowID < rhs.rowID
        }
    }

    /// Into rows already sorted, where the row each becomes will land.
    public static func merged(
        _ rows: [SessionRowModel],
        starting: [PendingDispatch],
        resolutions: SessionResolutions = SessionResolutions()
    ) -> [SessionListItem] {
        let items = rows.map(SessionListItem.session)
        guard !starting.isEmpty else { return items }

        let waiting = rows.prefix { bucket($0, resolutions: resolutions) == .blocked }.count
        let newest = starting
            .sorted { $0.startedAt > $1.startedAt }
            .map(SessionListItem.starting)

        return Array(items[..<waiting]) + newest + Array(items[waiting...])
    }

    public static func blockedCount(
        _ rows: [SessionRowModel],
        resolutions: SessionResolutions = SessionResolutions()
    ) -> Int {
        rows.count(where: resolutions.isWaitingOnYou)
    }
}
