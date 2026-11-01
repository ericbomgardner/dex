import Foundation

public struct NotificationDraft: Sendable, Hashable {
    public let title: String
    public let body: String

    /// What it is filed under: every row has one, not every row has a session.
    public let key: String

    public let sessionID: String?

    public let needsInput: Bool

    public init(title: String, body: String, key: String, sessionID: String?, needsInput: Bool) {
        self.title = title
        self.body = body
        self.key = key
        self.sessionID = sessionID
        self.needsInput = needsInput
    }

    public func shouldBeShown(alreadyOnScreen: Bool) -> Bool {
        needsInput || !alreadyOnScreen
    }
}
