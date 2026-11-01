import Foundation

public struct LaunchSpec: Sendable, Hashable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]

    public init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }

    public var argv: [String] { [executable] + arguments }
}

public enum RebuildCommand {

    public static let configuration = "release"

    public static let signingIdentityVariable = "DEX_CODESIGN_IDENTITY"

    /// Under the login shell's PATH: the app's own is launchd's, which has no
    /// homebrew and no nvm, and the script needs node and npm. The signing
    /// identity comes from there too, since an app opened from the Dock never
    /// sees the shell profile that sets it.
    public static func build(
        _ checkout: AppCheckout,
        loginPath: String?,
        signingIdentity: String?
    ) -> LaunchSpec {
        var environment: [String: String] = [:]
        if let loginPath { environment["PATH"] = loginPath }
        if let signingIdentity { environment[signingIdentityVariable] = signingIdentity }
        return LaunchSpec(
            executable: "/bin/bash",
            arguments: [
                checkout.scriptPath, Self.configuration,
            ],
            environment: environment
        )
    }

    /// What a pid has to look like to be killed as the host. A pid is a name
    /// only for as long as its process lives, and macOS hands pids out again.
    /// Checking the command line costs a `ps` and turns the worst case from
    /// killing a stranger into killing nothing.
    public static let hostMarker = "Sidecar/src/host.ts"

    /// Waits for this app to go, then opens the new bundle. The pid and the
    /// path are arguments rather than script text, so a bundle path with a
    /// quote in it stays a path.
    public static func relaunch(afterPID pid: Int32, bundlePath: String) -> LaunchSpec {
        LaunchSpec(
            executable: "/bin/sh",
            arguments: [
                "-c",
                #"""
                while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
                sleep 0.5
                exec open "$2"
                """#,
                "dex-relaunch",
                String(pid),
                bundlePath,
            ]
        )
    }

    /// The last line naming `bundleName`: the script prints one path per app
    /// it built, last thing, and the one to open is this app's own.
    public static func installedBundle(
        fromStdout stdout: String,
        bundleName: String = AppCheckout.Layout.bundleName
    ) -> String? {
        stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map({ $0.trimmingCharacters(in: .whitespaces) })
            .last(where: { ($0 as NSString).lastPathComponent == bundleName })
    }
}

public enum BuildLog {

    public static func failureMessage(stdout: String, stderr: String, exitCode: Int32) -> String {
        let errorLines = lines(stderr)
        let outputLines = lines(stdout)

        if let diagnostic = (errorLines + outputLines).first(where: { $0.contains("error:") }) {
            return shortenLeadingPath(in: diagnostic)
        }
        if let last = errorLines.last { return last }
        if let last = outputLines.last { return last }
        return "exited \(exitCode)"
    }

    private static func lines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private static func shortenLeadingPath(in line: String) -> String {
        guard line.hasPrefix("/"), let colon = line.firstIndex(of: ":") else { return line }
        let path = String(line[line.startIndex..<colon])
        let name = (path as NSString).lastPathComponent
        guard !name.isEmpty else { return line }
        return name + line[colon...]
    }
}
