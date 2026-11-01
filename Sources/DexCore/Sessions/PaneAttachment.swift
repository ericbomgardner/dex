import Foundation

/// The session held in the window's right-hand pane, keyed the way the host
/// keys it.
public struct PaneAttachment: Sendable, Hashable, Identifiable {

    public let hostKey: String

    public let workingDirectory: String?

    /// What the transcript pane needs to find the session's JSONL. Carried
    /// rather than resolved here: a session dispatched a moment ago has no
    /// transcript on disk yet, so the pane keeps looking.
    public let sessionID: String?

    /// Stands in for the transcript until there is one on disk to read.
    public let openingPrompt: String?

    public var id: String { hostKey }

    public init(
        hostKey: String,
        workingDirectory: String?,
        sessionID: String? = nil,
        openingPrompt: String? = nil
    ) {
        self.hostKey = hostKey
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.openingPrompt = openingPrompt
    }

    /// The SDK opens the transcript a beat after the session starts, so the id
    /// can arrive after the pane attached.
    public func adopting(sessionID: String) -> PaneAttachment {
        PaneAttachment(
            hostKey: hostKey,
            workingDirectory: workingDirectory,
            sessionID: sessionID,
            openingPrompt: openingPrompt
        )
    }
}
