import Foundation

/// Whether the running host is older than the app talking to it, and whether now
/// is a safe moment to replace it without asking.
///
/// The host outlives the app on purpose, so a fresh build sits beside a host
/// still running the old code until something ends that process. This is the
/// only thing that does, for a checkout's rebuild and an installed copy alike.
/// When the app is newer than the host *and* the
/// host says it is holding nothing, the app stops the host; `HostClient` puts a
/// new one up from the app's own bundle 600ms later, so the replacement is the
/// current build by construction. Gated hard on idleness because a replace ends
/// every session the host held — an idle one comes back on its next message by
/// resume, which costs a re-read and nothing else, but a turn in flight is lost.
public enum HostStaleness {

    /// Older by either signal. The build stamps are the general answer — any
    /// change to the sidecar moves the commit — and the SDK pair is the one that
    /// still fires when neither side carries a stamp. **Nil never reads as
    /// stale:** two absent stamps are a checkout or a host from before the field,
    /// not a match, so only two *present and different* stamps count.
    public static func isBehind(appBuild: String?, hostBuild: String?, sdk: HostSDK?) -> Bool {
        if let appBuild, let hostBuild, appBuild != hostBuild { return true }
        return sdk?.isBehind ?? false
    }

    /// The whole decision: stale, and the host says it is safe to stop.
    ///
    /// `busy` is the host's own reading, taken as its welcome is built and so
    /// free of the race an app-side row snapshot has with the `session.tasks`
    /// levels that arrive behind the welcome. **Nil is not false:** a host too
    /// old to answer is never stopped on a guess, which also means the first
    /// upgrade onto a build that has this needed the host killed by hand — the
    /// old host predates the signal.
    ///
    /// `afterReplacing` is the signature of the host the last automatic replace
    /// ended. A host that comes back with the same one was respawned from a
    /// bundle that is *not* this app's — the `.app` on disk was swapped under a
    /// running copy, by a rebuild say — and the app, not
    /// the host, is the stale one. Without this the app kills that host, gets
    /// the same host back 600ms later, and does it again for as long as it runs:
    /// measured at once a second for forty minutes, with a zombie per kill.
    public static func shouldReplace(
        appBuild: String?,
        hostBuild: String?,
        sdk: HostSDK?,
        busy: Bool?,
        afterReplacing replaced: String? = nil
    ) -> Bool {
        guard isBehind(appBuild: appBuild, hostBuild: hostBuild, sdk: sdk), busy == false
        else { return false }
        if let replaced, replaced == signature(hostBuild: hostBuild, sdk: sdk) { return false }
        return true
    }

    /// What names a host's code for the purpose above: its build stamp, or the
    /// SDK it loaded when there is no stamp to go by.
    public static func signature(hostBuild: String?, sdk: HostSDK?) -> String? {
        hostBuild ?? sdk?.loaded
    }
}
