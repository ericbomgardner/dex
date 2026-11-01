import Foundation

public enum ClaudeExecutable {

    static let fallbackLocations = [
        "~/.local/bin/claude",
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
    ]

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String {
        lookup(environment: environment, fileManager: fileManager).path
    }

    /// The path, and whether it is the answer: not when the login shell ran
    /// out of time and the path is a guess that asking again could beat.
    public static func lookup(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default,
        timeout: TimeInterval = 10
    ) -> (path: String, settled: Bool) {
        if let override = environment["CLAUDE_BINARY"],
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: expand(override)) {
            return (expand(override), true)
        }

        let asked = askLoginShell(environment: environment, timeout: timeout)
        if let fromShell = asked.path, fileManager.isExecutableFile(atPath: fromShell) {
            return (fromShell, true)
        }

        for candidate in fallbackLocations {
            let path = expand(candidate)
            if fileManager.isExecutableFile(atPath: path) { return (path, !asked.timedOut) }
        }

        return ("claude", !asked.timedOut)
    }

    private static func askLoginShell(
        environment: [String: String], timeout: TimeInterval
    ) -> (path: String?, timedOut: Bool) {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return (nil, false) }

        guard let result = try? Shell.run([shell, "-l", "-c", "command -v claude"], timeout: timeout)
        else { return (nil, false) }
        guard result.exitCode == 0, !result.timedOut else { return (nil, result.timedOut) }

        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (path.isEmpty ? nil : path, false)
    }

    static func expand(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }
}
