import Foundation

public enum LoginShell {

    private static let cachedPath = Lock<String?>(nil)
    private static let probed = Lock<Bool>(false)

    public static let guiFallbackPath = "/usr/bin:/bin:/usr/sbin:/sbin"

    public static func path(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        if probed.value { return cachedPath.value }
        let resolved = probePath(environment: environment)
        cachedPath.value = resolved
        probed.value = true
        return resolved
    }

    /// Whether `path()` would answer without running the shell.
    public static var isProbed: Bool { probed.value }

    static func probePath(environment: [String: String]) -> String? {
        probe("PATH", environment: environment)
    }

    /// A variable as the login shell sets it, which an app opened from the Dock
    /// never inherits. Asked afresh each call, and nil when unset or empty.
    public static func probe(
        _ variable: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let shell = environment["SHELL"] ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        // -i first: installers put ~/.local/bin and nvm in .zshrc; -l alone for an rc that execs tmux or fish.
        let command = "printf '\(marker)%s\(marker)' \"$\(variable)\""
        for flags in [["-i", "-l"], ["-l"]] {
            if let result = try? Shell.run([shell] + flags + ["-c", command], timeout: 10),
               let value = extract(from: result.stdoutText) {
                return value
            }
        }
        return nil
    }

    private static let marker = "__DEX_LOGIN_PATH__"

    static func extract(from output: String) -> String? {
        let parts = output.components(separatedBy: marker)
        guard parts.count >= 3 else { return nil }
        let path = parts[parts.count - 2]
        return path.isEmpty ? nil : path
    }
}

final class Lock<Value>: @unchecked Sendable {
    private var storage: Value
    private let mutex = NSLock()

    init(_ value: Value) { storage = value }

    var value: Value {
        get { mutex.withLock { storage } }
        set { mutex.withLock { storage = newValue } }
    }

    func withLock<T>(_ body: (inout Value) throws -> T) rethrows -> T {
        try mutex.withLock { try body(&storage) }
    }
}
