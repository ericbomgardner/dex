import Foundation

/// Which hosted sessions to rename so other sessions see their titles.
///
/// `ListAgents` shows another session only by its registry name, and a session
/// started without one keeps the folder-plus-hex name the CLI made up
/// (`sketch-67`) for good: its own titles never reach the registry. A live
/// rename does, at the cost of the CLI generating no further titles for it.
public enum SessionNaming {

    public struct Rename: Equatable, Sendable {
        public let sessionId: String
        public let title: String
    }

    public static func renames(
        _ rows: [SessionRowModel],
        registry: [String: SessionRegistry.Entry]
    ) -> [Rename] {
        rows.compactMap { row in
            guard
                  let sessionId = row.session.sessionId,
                  registry[sessionId]?.isDerived == true,
                  let title = row.session.chosenName?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !title.isEmpty,
                  // A session opened with a slash command goes by the command until the CLI titles it.
                  !title.hasPrefix("/")
            else { return nil }
            return Rename(sessionId: sessionId, title: title)
        }
    }
}
