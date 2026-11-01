import Foundation

/// A pull request or issue, through the `gh` the user has already logged in.
/// The issues endpoint answers for both, and for a PR carries
/// `pull_request.merged_at`, so one call covers title, state and merged.
public struct GitHubLinkLookup: ExternalLinkLookup {
    /// Runs `gh` with these arguments; nil when there is no `gh` to run.
    public typealias Runner = @Sendable ([String]) async throws -> CommandResult?

    private let run: Runner

    public init(run: @escaping Runner = GitHubCLI.run) {
        self.run = run
    }

    public func resolve(_ link: PastedLink) async throws -> LinkResolution? {
        guard case .github(let github) = link else { return nil }
        let path = "repos/\(github.owner)/\(github.repo)/issues/\(github.number)"
        guard let result = try await run(["api", "-H", "Accept: application/vnd.github+json", path]) else {
            return nil
        }
        guard result.exitCode == 0 else {
            if GitHubCLI.isLoggedOut(result.stderr) { return nil }
            throw PastedLinkError.service(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return try GitHubIssue.parse(result.stdout, link: github)
    }
}

public enum GitHubIssue {

    /// `GET /repos/{owner}/{repo}/issues/{number}`.
    public static func parse(_ data: Data, link: GitHubLink) throws -> LinkResolution {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = root["title"] as? String
        else { throw PastedLinkError.unreadable }

        let isOpen = (root["state"] as? String) == "open"
        let pull = root["pull_request"] as? [String: Any]
        let state: LinkState
        if let pull {
            if pull["merged_at"] is String {
                state = .merged
            } else if !isOpen {
                state = .closed
            } else {
                state = root["draft"] as? Bool == true ? .draft : .open
            }
        } else if isOpen {
            state = .open
        } else {
            state = (root["state_reason"] as? String) == "not_planned" ? .closed : .done
        }

        let what = pull == nil ? "Issue" : "PR"
        let said = switch state {
        case .open: "open"
        case .draft: "draft"
        case .merged: "merged"
        case .closed: pull == nil ? "not planned" : "closed"
        case .done: "closed"
        }
        return LinkResolution(title: title, detail: "\(what) \(link.reference) · \(said)", state: state)
    }
}

/// Finding and running `gh` from an app, which starts with launchd's PATH
/// rather than the shell's, so `gh` alone is never found.
public enum GitHubCLI {

    static let fallbackLocations = [
        "/opt/homebrew/bin/gh",
        "/usr/local/bin/gh",
        "~/.local/bin/gh",
        "~/.nix-profile/bin/gh",
        "/run/current-system/sw/bin/gh",
        "/usr/bin/gh",
    ]

    private static let found = Lock<String??>(nil)

    /// The shell's PATH first, since that is the `gh` the user logged in with
    /// in the Terminal; then this process's own; then where installers put it.
    public static func locate(
        loginPath: String?,
        processPath: String? = ProcessInfo.processInfo.environment["PATH"],
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> String? {
        let directories = [loginPath, processPath]
            .compactMap { $0 }
            .flatMap { $0.split(separator: ":").map(String.init) }
            .filter { !$0.isEmpty }
        let candidates = directories.map { ($0 as NSString).appendingPathComponent("gh") }
            + fallbackLocations.map { ($0 as NSString).expandingTildeInPath }
        return candidates.first(where: isExecutable)
    }

    /// Located once per launch. A `gh` installed after that is found next launch.
    public static func executable() -> String? {
        if let known = found.value { return known }
        let located = locate(loginPath: LoginShell.path())
        found.value = .some(located)
        return located
    }

    @Sendable
    public static func run(_ arguments: [String]) async throws -> CommandResult? {
        try await Task.detached {
            guard let gh = executable() else { return nil }
            var environment = ["GH_PROMPT_DISABLED": "1", "NO_COLOR": "1", "GH_NO_UPDATE_NOTIFIER": "1"]
            if let path = LoginShell.path() { environment["PATH"] = path }
            return try Shell.run([gh] + arguments, environment: environment, timeout: 15)
        }.value
    }

    /// What `gh` says when it has no account to ask with, which is a missing
    /// credential rather than a failed lookup.
    static func isLoggedOut(_ stderr: String) -> Bool {
        stderr.contains("gh auth login") || stderr.contains("not logged into")
    }
}
