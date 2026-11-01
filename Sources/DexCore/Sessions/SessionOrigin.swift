import Foundation

/// What started a session that wasn't started by hand: a background watcher,
/// by the name its status file goes by, and why it started this one — or
/// another session, by its key, through the host's `start_session` tool.
public struct SessionOrigin: Codable, Hashable, Sendable {
    public var watcher: String?
    public var reason: String?
    public var parent: String?

    public init(watcher: String? = nil, reason: String? = nil, parent: String? = nil) {
        self.watcher = watcher
        self.reason = reason
        self.parent = parent
    }
}
