import DexCore
import Foundation

/// Which `claude` binary the app asks about itself.
@MainActor
final class ClaudeLookup {
    /// The typed CLI, the fallback below. Resolved once, off the main actor and
    /// only when first wanted, because finding it means asking the login shell,
    /// and the PATH does not move under a running app. A shell that ran out of
    /// time isn't an answer, so that lookup is made again next time.
    private var installedClaude: String?
    private var installedClaudeLookup: Task<(path: String, settled: Bool), Never>?

    /// The CLI the app asks about itself: the SDK's, since that is the one its
    /// sessions run. The typed one stands in only where there is no bundle to
    /// ask, since a version off the wrong binary still beats a row that can say
    /// nothing at all.
    ///
    /// Asked each time rather than settled at launch. A checkout whose
    /// dependencies aren't installed yet has no bundled CLI to find, and a
    /// rebuild takes `node_modules` away and puts it back — either would
    /// otherwise latch the fallback for the life of the app and quietly go on
    /// describing the wrong binary long after the right one was there.
    func executable() async -> String {
        if let bundled = HostLocation.bundledCLI() { return bundled }
        if let installedClaude { return installedClaude }
        let lookup = installedClaudeLookup ?? Task.detached(priority: .utility) { ClaudeExecutable.lookup() }
        installedClaudeLookup = lookup
        let found = await lookup.value
        if installedClaudeLookup == lookup { installedClaudeLookup = nil }
        if found.settled { installedClaude = found.path }
        return found.path
    }
}
