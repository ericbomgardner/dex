import Foundation

/// The names the app is known by: its bundle id, the prefix its queues and
/// pasteboard types are under, and the bundle the build writes.
public enum BundleIdentity {
    public static let prefix = "com.toiptoip"
    public static let code = prefix + ".dex"
    public static let codeBundle = "Dex.app"
    /// Under the config directory: the host's socket and state, and the fleet
    /// file. The host's `SUPPORT_FOLDER` names the same one.
    public static let supportFolder = "dex"
}
