import Foundation

/// A stretch of calls said as one line of what was done — "Read Foo.swift and
/// 3 others, searched for “atEnd”, ran swift test (failed)" — built from the
/// calls' own inputs, so it reads the same for every transcript, old or new.
///
/// `Scripts/maintainer/transcript-render.py` builds the same sentence; keep the two in step.
public enum RunSentence {

    /// A command longer than this reads as noise, and the model's own
    /// description of it reads better.
    static let commandLimit = 40

    private struct Clause {
        let verb: String
        var objects: [String] = []
        var failed: Set<String> = []
        var failures = 0
        var droppedObjects: Set<String> = []
        var dropped = 0
    }

    public static func of(_ calls: [ToolCall]) -> String {
        var clauses: [Clause] = []
        for call in calls {
            let (verb, object) = phrase(call)
            let failed = call.result?.isError == true && !call.neverCameBack
            if clauses.last?.verb != verb { clauses.append(Clause(verb: verb)) }
            if failed { clauses[clauses.count - 1].failures += 1 }
            if call.wasDropped { clauses[clauses.count - 1].dropped += 1 }
            guard let object else { continue }
            if !clauses[clauses.count - 1].objects.contains(object) { clauses[clauses.count - 1].objects.append(object) }
            if failed { clauses[clauses.count - 1].failed.insert(object) }
            if call.wasDropped { clauses[clauses.count - 1].droppedObjects.insert(object) }
        }
        let sentence = clauses.map(said).joined(separator: ", ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }

    /// A verb shared by its objects ("read A and B"), or, for a command the
    /// model described, the descriptions themselves, which are clauses already
    /// and can't share an "and" without reading as one.
    private static func said(_ clause: Clause) -> String {
        func marked(_ object: String) -> String {
            if clause.droppedObjects.contains(object) { return "\(object) (\(ToolCall.droppedNote))" }
            return clause.failed.contains(object) ? "\(object) (failed)" : object
        }
        let objects = clause.objects
        let listed: String? = switch objects.count {
        case 0: clause.failures > 0 ? "(failed)" : nil
        case 1: marked(objects[0])
        case 2: clause.verb.isEmpty
            ? "\(marked(objects[0])), \(marked(objects[1]))"
            : "\(marked(objects[0])) and \(marked(objects[1]))"
        default: clause.verb.isEmpty
            ? "\(objects[0]) and \(objects.count - 1) more commands" + tally(clause)
            : "\(objects[0]) and \(objects.count - 1) others" + tally(clause)
        }
        return [clause.verb, listed].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    private static func tally(_ clause: Clause) -> String {
        let counts = [
            clause.failures > 0 ? "\(clause.failures) failed" : nil,
            clause.dropped > 0 ? "\(clause.dropped) \(ToolCall.droppedNote)" : nil,
        ].compactMap { $0 }
        return counts.isEmpty ? "" : " (\(counts.joined(separator: ", ")))"
    }

    static func phrase(_ call: ToolCall) -> (verb: String, object: String?) {
        switch call.name {
        case "Read": ("read", file(call))
        case "Edit", "MultiEdit", "NotebookEdit": ("edited", file(call))
        case "Write": ("wrote", file(call))
        case "Grep": ("searched for", call.argument("pattern").map(quoted))
        case "Glob": ("looked for", call.argument("pattern").map(quoted))
        case "Bash": command(call)
        case "BashOutput": ("checked", "a shell")
        case "WebFetch": ("fetched", call.argument("url").map(host))
        case "WebSearch": ("searched the web for", call.argument("query").map(quoted))
        case "Skill": ("ran", (call.argument("skill") ?? call.argument("command")).map { "/\($0)" })
        case "ToolSearch": ("loaded", "tools")
        case "Monitor": ("watched", call.argument("description"))
        default: mcp(call.name) ?? ("used", call.name)
        }
    }

    private static func file(_ call: ToolCall) -> String? {
        (call.argument("file_path") ?? call.argument("notebook_path")).map { ($0 as NSString).lastPathComponent }
    }

    private static func quoted(_ text: String) -> String {
        "“\(text.count > commandLimit ? text.prefix(commandLimit) + "…" : text)”"
    }

    private static func host(_ url: String) -> String {
        URL(string: url)?.host ?? url
    }

    /// The command as typed when it is one short line, once a leading
    /// `cd somewhere &&` is off it. Otherwise the model's description of it,
    /// which is a clause of its own ("run the test suite"), so it takes no verb.
    private static func command(_ call: ToolCall) -> (verb: String, object: String?) {
        let description = call.argument("description").map { clauseCase(PastTense.of($0)) }
        guard let typed = call.argument("command")?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return description.map { ("", $0) } ?? ("ran", nil)
        }
        var line = typed.components(separatedBy: "\n")[0]
        if line.hasPrefix("cd "), let and = line.range(of: "&& ") {
            line = String(line[and.upperBound...])
        }
        if line.count <= commandLimit, !typed.contains("\n") || description == nil { return ("ran", line) }
        if let description { return ("", description) }
        return ("ran", line.prefix(commandLimit) + "…")
    }

    /// "Run tests" as "run tests", but "CI logs" as itself.
    private static func clauseCase(_ text: String) -> String {
        if text.dropFirst().first?.isUppercase == true { return text }
        return text.prefix(1).lowercased() + text.dropFirst()
    }

    /// `mcp__server__tool` as "called tool (server)".
    private static func mcp(_ name: String) -> (verb: String, object: String?)? {
        let parts = name.components(separatedBy: "__")
        guard parts.count >= 3, parts[0] == "mcp" else { return nil }
        return ("called", "\(parts[2...].joined(separator: "__")) (\(parts[1]))")
    }
}
