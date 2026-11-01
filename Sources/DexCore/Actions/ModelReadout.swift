import Foundation

/// What the CLI says it would run for a given choice, in its own words.
///
/// `claude -p "/model"` answers ``Current model: `Opus 5 (1M context)
/// (default)` (effort: xhigh)``, and the same question under `--model sonnet`
/// answers ``Current model: `Sonnet 5` ``. So the picker's rows are named by
/// the CLI rather than by the app, which is what lets a row say `5` without a
/// table to go stale. Read against **CLI v2.1.241**.
public enum ModelReadout {

    /// Nil rather than a guess: an unread name costs a row its version, and a
    /// wrong one names a model you are not going to get.
    public static func read(_ model: SessionModel, executable: String) -> String? {
        guard let result = try? Shell.run([executable, "-p", "--no-session-persistence"] + model.flagArguments + ["/model"]),
              result.exitCode == 0
        else { return nil }
        return name(in: result.stdoutText)
    }

    static let lead = "Current model: "

    /// The markers the CLI writes after the name. The name has parentheses of
    /// its own — `Opus 5 (1M context)` — so they come off by what they say
    /// rather than by being last. The context window goes with them: the choice
    /// is between classes, and a note every row could carry tells you nothing.
    static func isMarker(_ text: String) -> Bool {
        text == "default"
            || text.hasPrefix("effort:")
            || text.hasSuffix("context")
            || text.hasSuffix("from plan mode")
    }

    static func name(in output: String) -> String? {
        guard let line = output
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first(where: { $0.hasPrefix(lead) })
        else { return nil }

        // Trailing space has to come off each time round: the markers are
        // separated by one, and it is what says the next one has ended.
        var name = Substring(line.dropFirst(lead.count)).trimmedRight()

        // Two rounds, because the CLI backticks the name and some of its
        // markers together: `effort:` sits outside the quoting and `default`
        // inside it, so a single pass stops at the closing backtick.
        while true {
            let before = name
            name = stripMarkers(from: name)
            name = unquoted(name)
            if name == before { break }
        }

        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func stripMarkers(from text: Substring) -> Substring {
        var name = text
        while let opened = name.lastIndex(of: "("), name.hasSuffix(")") {
            let inside = name[name.index(after: opened)..<name.index(before: name.endIndex)]
            guard isMarker(inside.trimmingCharacters(in: .whitespaces)) else { break }
            name = name[..<opened].trimmedRight()
        }
        return name
    }

    static func unquoted(_ text: Substring) -> Substring {
        guard text.count > 1, text.hasPrefix("`"), text.hasSuffix("`") else { return text }
        return text.dropFirst().dropLast().trimmedRight()
    }
}

extension Substring {
    func trimmedRight() -> Substring {
        guard let last = lastIndex(where: { !$0.isWhitespace }) else { return self[startIndex..<startIndex] }
        return self[...last]
    }
}
