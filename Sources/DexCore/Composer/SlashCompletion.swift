import Foundation

/// What the composer offers while you are typing a command's name.
///
/// A slash only starts a command at the very beginning of a message — anywhere
/// else it is a path, a fraction or an and/or — so the menu is offered for the
/// first word and nothing after it.
public enum SlashCompletion {

    /// Long enough to be a name, short enough to say the field has moved on to
    /// prose: a real command is one word.
    public static func query(in draft: String) -> String? {
        guard draft.hasPrefix("/") else { return nil }
        let typed = draft.dropFirst()
        guard !typed.contains(where: \.isWhitespace) else { return nil }
        return String(typed)
    }

    public static func matches(
        for draft: String,
        in commands: [Command],
        limit: Int = 8
    ) -> [Command] {
        guard let query = query(in: draft) else { return [] }
        guard !query.isEmpty else { return Array(commands.prefix(limit)) }

        let scored = commands.compactMap { command -> (Command, Int)? in
            guard let match = FuzzyMatch.match(query, in: command.name) else { return nil }
            return (command, match.score)
        }

        return scored
            // A name that simply starts with what you typed is what you meant,
            // however well something else scores in the middle.
            .sorted { left, right in
                let leading = (starts(left.0, with: query), starts(right.0, with: query))
                if leading.0 != leading.1 { return leading.0 }
                if left.1 != right.1 { return left.1 > right.1 }
                return left.0.name < right.0.name
            }
            .prefix(limit)
            .map(\.0)
    }

    /// What the field should read once a command is taken: the name and a space,
    /// so whatever the command takes can be typed straight after it. Text
    /// after the caret stays where it was.
    public static func accepting(_ command: Command, in draft: String, caret: String? = nil) -> String {
        let (head, tail) = ComposerChips.split(draft, at: caret)
        guard query(in: head) != nil else { return draft }
        return command.typed + ComposerChips.joiner(before: tail) + tail
    }

    private static func starts(_ command: Command, with query: String) -> Bool {
        command.name.lowercased().hasPrefix(query.lowercased())
    }
}
