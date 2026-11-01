import Foundation

public enum SessionTransitions {

    public static func notifications(
        from previous: [SessionRowModel],
        to current: [SessionRowModel],
        resolutions: SessionResolutions = SessionResolutions()
    ) -> [NotificationDraft] {
        guard !previous.isEmpty else { return [] }

        var before: [String: SessionRowModel] = [:]
        before.reserveCapacity(previous.count)
        for row in previous { before[row.rowID] = row }

        return current.compactMap { row -> NotificationDraft? in
            // Read here as withdrawal reads it, or a settled row is announced and
            // then taken straight back off you.
            guard !resolutions.isSettled(row) else { return nil }

            return switch change(from: before[row.rowID], to: row) {
            case .none: nil
            case .blocked: draft(for: row, needsInput: true)
            case .finished: draft(for: row, needsInput: false)
            }
        }
    }

    /// The rows whose notification still says something true.
    public static func standing(
        in rows: [SessionRowModel],
        resolutions: SessionResolutions,
        onScreen: Set<String>
    ) -> Set<String> {
        var standing: Set<String> = []
        for row in rows where !resolutions.isSettled(row) {
            if row.isAsking
                || (isFinished(row.session.state) && !onScreen.contains(row.rowID)) {
                standing.insert(row.rowID)
            }
        }
        return standing
    }

    enum Change { case none, blocked, finished }

    static func change(from previous: SessionRowModel?, to current: SessionRowModel) -> Change {
        guard let previous else {
            return current.isAsking ? .blocked : .none
        }

        if current.isAsking {
            return previous.isAsking ? .none : .blocked
        }
        if isFinished(current.session.state), !isFinished(previous.session.state) {
            return .finished
        }
        return .none
    }

    private static func isFinished(_ state: HostSessionState) -> Bool {
        state.isFinished
    }

    /// A banner is one line and carries no folder under it the way the row does,
    /// so a session the CLI hasn't named yet is announced by where it is running
    /// rather than by the placeholder the list can afford. A first turn that
    /// fails outright never gets a name at all — that notice is the one this is
    /// for, and every one of them would otherwise read the same.
    private static func name(for row: SessionRowModel) -> String {
        row.session.chosenName ?? row.session.folderName
    }

    /// Posted the moment a session is let onto the screen, so it reaches you
    /// wherever you are looking — which, if the session is driving the pointer,
    /// is not at Dex. Filed under the row like the rest, and retracted with the
    /// takeover.
    public static func takeoverDraft(for row: SessionRowModel, doing: String?) -> NotificationDraft {
        NotificationDraft(
            title: "Driving your screen: \(name(for: row))",
            body: doing ?? "The session is using the pointer or keyboard.",
            key: row.rowID,
            sessionID: row.session.sessionId,
            needsInput: false
        )
    }

    private static func draft(for row: SessionRowModel, needsInput: Bool) -> NotificationDraft {
        let name = name(for: row)
        return NotificationDraft(
            title: needsInput ? "Input needed: \(name)" : "\(outcome(row.session.state)): \(name)",
            body: row.summary,
            key: row.rowID,
            sessionID: row.session.sessionId,
            needsInput: needsInput
        )
    }

    private static func outcome(_ state: HostSessionState) -> String {
        state == .failed ? "Failed" : "Finished"
    }
}
