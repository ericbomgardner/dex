import Foundation

/// What the process holding the socket loaded, against what a host started this
/// second would load.
///
/// Two readings of the same `package.json` taken at different moments, and the
/// gap between them is the whole of what the app can see about a host that has
/// outlived several builds. The host is deliberately not rebuilt with the app,
/// so a session started this morning is driven by SDK code from whenever that
/// process began — and nothing said so, because the version in the welcome was
/// read off disk as the welcome was written and so always named the newest
/// build rather than the running one.
///
/// It is the SDK half alone that is behind. The `claude` beside it is spawned
/// per session, by path, so a build replaces it under a running host and the
/// next session picks it up without anyone restarting anything. A note here that
/// said "your sessions are old" would be wrong about the CLI and right about the
/// SDK, which is why it names the SDK.
public struct HostSDK: Equatable, Sendable {
    /// Frozen at the host's start.
    public let loaded: String
    /// Absent from a host older than the field, which can say nothing about
    /// itself and is left saying nothing rather than guessed at.
    public let onDisk: String?

    public init(loaded: String, onDisk: String?) {
        self.loaded = loaded
        self.onDisk = onDisk
    }

    /// Compared as versions rather than as text, so 0.3.9 sorts below 0.3.10 —
    /// `CLIVersion` is the same three-part comparison and the SDK rides the same
    /// release train the CLI does.
    public var isBehind: Bool {
        guard let onDisk,
            let loaded = CLIVersion(loaded),
            let disk = CLIVersion(onDisk)
        else { return false }
        return loaded < disk
    }
}
