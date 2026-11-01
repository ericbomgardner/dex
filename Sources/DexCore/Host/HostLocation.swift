import Foundation

/// Where the host lives, and what runs it.
///
/// Both answers are awkward from a GUI app: launched from Finder it inherits no
/// login `PATH`, so `node` has to be found through the login shell, and the
/// sidecar sits beside the sources in a checkout but inside
/// `Contents/Resources` in a bundle.
public struct HostLocation: Sendable {
    /// The unix socket's path.
    public let socket: String
    /// The sidecar's entry point, and the node that runs it.
    public let entry: String
    public let node: String

    public init(
        socket: String, entry: String, node: String
    ) {
        self.socket = socket
        self.entry = entry
        self.node = node
    }

    public static func socketPath(
        identity: HostIdentity = .code,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let override = environment[identity.socketOverride], !override.isEmpty {
            return (override as NSString).expandingTildeInPath
        }
        let configDirectory = ConfigDirectory.resolve(environment: environment)
        return configDirectory.appendingPathComponent(identity.socketSubpath).path
    }

    /// A unix socket path is capped near 104 bytes by the kernel, and a
    /// `CLAUDE_CONFIG_DIR` deep enough to breach it would otherwise fail at
    /// `bind` with nothing pointing at the cause.
    public static let socketPathLimit = 104

    /// The node the app ships, as a helper bundle with its own identifier.
    ///
    /// Bundled for the identity, not the convenience. macOS attributes a screen
    /// recording or accessibility request to the process responsible for it,
    /// and the host outlives the app that spawned it, so the grant has to
    /// belong to the host in its own right. A bundle identifier under a
    /// certificate is the one identity that survives a rebuild, a worktree
    /// build and a `brew upgrade node`; a bare binary is known by its path.
    public static func bundledNode(
        identity: HostIdentity = .code,
        bundleURL: URL? = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> String? {
        guard let bundleURL else { return nil }
        let candidate = bundleURL.appendingPathComponent(identity.helperExecutable).path
        return fileManager.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// The fallback for a checkout and the tests, which have no bundle to look in.
    public static func node(
        searching path: String?,
        fileManager: FileManager = .default
    ) -> String? {
        tool("node", searching: path, fileManager: fileManager)
    }

    /// A GUI process inherits launchd's PATH — `/usr/bin:/bin` and nothing
    /// else — so anything homebrew installed is searched for by the same short
    /// list `make-app.sh` walks, after whatever PATH the caller could find.
    public static func tool(
        _ name: String,
        searching path: String?,
        fileManager: FileManager = .default
    ) -> String? {
        let candidates =
            (path?.split(separator: ":").map(String.init) ?? [])
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

        for directory in candidates where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileManager.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// Searched rather than computed: a checkout runs it from `Sidecar/`, a
    /// bundle from `Contents/Resources/Sidecar/`, and the tests from neither.
    public static func entryPath(
        bundle: Bundle = .main,
        executable: URL = URL(fileURLWithPath: CommandLine.arguments.first ?? ""),
        fileManager: FileManager = .default
    ) -> String? {
        var roots: [URL] = []
        if let resources = bundle.resourceURL {
            roots.append(resources.appendingPathComponent("Sidecar"))
        }

        // Walk up from the binary so a `swift run` build finds the checkout's copy.
        var directory = executable.deletingLastPathComponent()
        for _ in 0..<8 {
            roots.append(directory.appendingPathComponent("Sidecar"))
            directory = directory.deletingLastPathComponent()
        }

        for root in roots {
            let candidate = root.appendingPathComponent("src/host.ts")
            if fileManager.isReadableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    /// The `claude` the SDK ships, which is the one every hosted session runs.
    ///
    /// Found beside the host rather than on the PATH, because it is a different
    /// binary from the one you type and on a different clock: that one updates
    /// itself, this one moves when `Scripts/make-app.sh` moves the pin. Anything
    /// the app asks about "the CLI" for its own sake — what version its sessions
    /// are on, what the model picker's rows are called — has to ask this one, or
    /// it is describing a binary that isn't running its work.
    ///
    /// The platform package is searched for rather than named: npm installs one
    /// of `claude-agent-sdk-darwin-arm64` or `-x64` by architecture, and naming
    /// one of them answers nil on the machine that has the other.
    public static func bundledCLI(
        entry: String? = entryPath(),
        fileManager: FileManager = .default
    ) -> String? {
        guard let entry else { return nil }
        let packages = URL(fileURLWithPath: entry)
            .deletingLastPathComponent()  // src
            .deletingLastPathComponent()  // Sidecar
            .appendingPathComponent("node_modules/@anthropic-ai")

        let contents = (try? fileManager.contentsOfDirectory(
            at: packages,
            includingPropertiesForKeys: nil
        )) ?? []

        for package in contents.sorted(by: { $0.path < $1.path })
        where package.lastPathComponent.hasPrefix("claude-agent-sdk-darwin-") {
            let candidate = package.appendingPathComponent("claude")
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case nodeMissing
        case sidecarMissing
        case socketPathTooLong(String)

        public var description: String {
            switch self {
            case .nodeMissing:
                "node was found neither in the app bundle nor on the login PATH; the host needs Node 22.18 or newer"
            case .sidecarMissing:
                "the Sidecar directory was not found beside the app or its sources"
            case .socketPathTooLong(let path):
                "the socket path is \(path.utf8.count) bytes, past the \(socketPathLimit) a unix socket allows: \(path)"
            }
        }
    }

    public static func resolve(
        identity: HostIdentity = .code,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        loginPath: () -> String?,
        bundle: Bundle = .main
    ) throws -> HostLocation {
        let socket = socketPath(identity: identity, environment: environment)
        guard socket.utf8.count < socketPathLimit else {
            throw Failure.socketPathTooLong(socket)
        }
        guard
            let node = bundledNode(identity: identity, bundleURL: bundle.bundleURL)
                ?? node(searching: loginPath() ?? environment["PATH"])
        else {
            throw Failure.nodeMissing
        }
        guard let entry = entryPath(bundle: bundle) else {
            throw Failure.sidecarMissing
        }
        return HostLocation(
            socket: socket, entry: entry, node: node
        )
    }
}
