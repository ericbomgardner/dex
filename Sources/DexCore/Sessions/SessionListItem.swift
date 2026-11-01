import Foundation

public enum SessionListItem: Identifiable, Sendable, Hashable {
    case starting(PendingDispatch)
    case session(SessionRowModel)

    public var id: String {
        switch self {
        case .starting(let dispatch): "starting:\(dispatch.id.uuidString)"
        case .session(let row): row.rowID
        }
    }
}
