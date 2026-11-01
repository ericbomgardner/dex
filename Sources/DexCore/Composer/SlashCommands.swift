import Foundation

public struct Command: Equatable, Sendable, Identifiable {

    /// Without the slash: what you would have typed after it.
    public let name: String

    public let summary: String

    /// Custom commands are worth saying so, since where they came from is the
    /// only way to tell one from a command the CLI ships with.
    public let isCustom: Bool

    /// Whether the session would actually run it. The CLI ships a great many
    /// commands that only open a panel in a terminal, and one of those reaches
    /// a hosted session as a turn spent on a refusal — so they are shown and
    /// not offered, rather than hidden. True where nobody has said.
    public let isAvailable: Bool

    public var id: String { name }

    public init(
        name: String,
        summary: String,
        isCustom: Bool = false,
        isAvailable: Bool = true
    ) {
        self.name = name
        self.summary = summary
        self.isCustom = isCustom
        self.isAvailable = isAvailable
    }

    public var typed: String { "/" + name }
}

/// Every command the field can offer: the ones the CLI ships with, recorded by
/// `Scripts/slash-command-probe.py`, plus whatever the user and the project have
/// written into `commands` or `skills` under the config directory or the
/// project's `.claude`. The CLI reads both —
/// `commands/deploy.md` and `skills/deploy/SKILL.md` each answer to `/deploy`.
public enum SlashCommands {

    public static func all(
        forProject project: String?,
        configDirectory: String = ConfigDirectory.resolve().path,
        reading directory: (String) -> [CommandFile] = CommandFile.read,
        readingSkills skills: (String) -> [CommandFile] = CommandFile.readSkills
    ) -> [Command] {
        var byName: [String: Command] = [:]
        var order: [String] = []

        func add(_ command: Command) {
            if byName[command.name] == nil { order.append(command.name) }
            // A project's own command wins: it is the one that would run.
            byName[command.name] = command
        }

        for command in BuiltInCommands.all { add(command) }

        for scope in scopes(forProject: project, configDirectory: configDirectory) {
            for file in directory(scope + "/commands") + skills(scope + "/skills") {
                add(Command(name: file.name, summary: file.summary, isCustom: true))
            }
        }

        return order.compactMap { byName[$0] }.sorted { $0.name < $1.name }
    }

    /// The catalogue stamped with what the session says it will run, off the
    /// `slash_commands` its CLI names at `init`.
    ///
    /// A filter and never a source. That list is the running CLI's whole
    /// dispatch table and carries housekeeping nobody types — `heapdump`,
    /// `autocompact`, `__remote-workflow` — so a name in it the catalogue
    /// doesn't have is not one to start offering. Nil means nobody has said —
    /// an archived row, or a host from before this was on the wire — and then
    /// everything stands, since greying the lot is worse than greying none.
    ///
    /// Custom commands are stamped like the rest rather than exempted: a
    /// command written to disk mid-session is one the catalogue can see and the
    /// running CLI cannot, and greying it is the true answer.
    public static func marked(_ commands: [Command], live: Set<String>?) -> [Command] {
        guard let live else { return commands }
        return commands.map { command in
            let runs = live.contains(command.name)
            guard runs != command.isAvailable else { return command }
            return Command(
                name: command.name,
                summary: command.summary,
                isCustom: command.isCustom,
                isAvailable: runs
            )
        }
    }

    /// The user's first, so a project of the same name lands on top of it. The
    /// user's are wherever `CLAUDE_CONFIG_DIR` points, and only there.
    static func scopes(forProject project: String?, configDirectory: String) -> [String] {
        var scopes = [configDirectory]
        if let project, !project.isEmpty {
            scopes.append(project + "/.claude")
        }
        return scopes
    }
}

/// One `.md` file under a `commands` directory, or one `SKILL.md` under a
/// `skills` directory.
public struct CommandFile: Equatable, Sendable {
    public let name: String
    public let summary: String

    public init(name: String, summary: String) {
        self.name = name
        self.summary = summary
    }

    public static func read(root: String) -> [CommandFile] {
        let base = URL(fileURLWithPath: root, isDirectory: true)
        guard let walk = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return walk.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
                return CommandFile(name: name(of: url, under: base), summary: summary(of: text))
            }
            .sorted { $0.name < $1.name }
    }

    public static func readSkills(root: String) -> [CommandFile] {
        let base = URL(fileURLWithPath: root, isDirectory: true)
        guard let walk = FileManager.default.enumerator(
            at: base,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return walk.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == "SKILL.md" }
            .compactMap { url in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      !hidesItself(text)
                else { return nil }
                let name = skillName(of: url, under: base)
                return name.isEmpty ? nil : CommandFile(name: name, summary: summary(of: text))
            }
            .sorted { $0.name < $1.name }
    }

    /// A command in a folder is addressed through it, the way the CLI reads them:
    /// `commands/review/api.md` is `/review:api`.
    static func name(of url: URL, under base: URL) -> String {
        var parts = Array(trail(of: url, under: base))
        if let last = parts.popLast() { parts.append((last as NSString).deletingPathExtension) }
        return parts.joined(separator: ":")
    }

    /// A skill is addressed by the directory holding its `SKILL.md`. Its
    /// frontmatter `name` is only the label shown in listings — reading the
    /// command off it would rename commands the CLI never renamed.
    static func skillName(of url: URL, under base: URL) -> String {
        trail(of: url.deletingLastPathComponent(), under: base).joined(separator: ":")
    }

    /// What is left of a path once the directory it was found in is taken off
    /// the front. Both sides are resolved first, because a walk of `/var` hands
    /// back `/private/var` and the extra component would land in the name.
    private static func trail(of url: URL, under base: URL) -> ArraySlice<String> {
        let root = base.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            .dropFirst(root.count)
    }

    /// `user-invocable: false` is how a skill says it is background knowledge
    /// rather than something to type. It defaults to true, so only the word
    /// false hides one.
    static func hidesItself(_ text: String) -> Bool {
        frontmatter("user-invocable", in: text)?.lowercased() == "false"
    }

    /// The `description:` a command gives itself, or failing that its first line
    /// of prose — which is what the CLI falls back to as well.
    static func summary(of text: String) -> String {
        if let described = frontmatter("description", in: text) { return described }

        for line in body(of: text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, trimmed != "---", !trimmed.hasPrefix("#") else { continue }
            return trimmed
        }
        return ""
    }

    /// What follows the frontmatter, so a file that never described itself falls
    /// back to its prose rather than to whichever field happens to come first.
    static func body(of text: String) -> [Substring] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let close = lines.dropFirst().firstIndex(where: {
                  $0.trimmingCharacters(in: .whitespaces) == "---"
              })
        else { return lines }
        return Array(lines[lines.index(after: close)...])
    }

    static func frontmatter(_ key: String, in text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }

        for line in lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" { return nil }
            guard trimmed.lowercased().hasPrefix(key + ":") else { continue }
            return unquoted(String(trimmed.dropFirst(key.count + 1)))
        }
        return nil
    }

    private static func unquoted(_ text: String) -> String {
        var value = text.trimmingCharacters(in: .whitespaces)
        for quote in ["\"", "'"] where value.hasPrefix(quote) && value.hasSuffix(quote) {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
