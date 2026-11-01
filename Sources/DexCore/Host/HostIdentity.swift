import Foundation

/// Which local host the app talks to: its socket, and the helper bundle it
/// runs under.
public struct HostIdentity: Sendable, Hashable {

    /// Under the config directory.
    public let socketSubpath: String

    /// The environment variable that points the app at another socket.
    public let socketOverride: String

    /// See `HostLocation.bundledNode` for why the host runs under a bundle of
    /// its own.
    public let helperExecutable: String

    public static let code = HostIdentity(
        socketSubpath: BundleIdentity.supportFolder + "/host.sock",
        socketOverride: "DEX_HOST_SOCKET",
        helperExecutable: "Contents/Helpers/DexHost.app/Contents/MacOS/DexHost"
    )

}
