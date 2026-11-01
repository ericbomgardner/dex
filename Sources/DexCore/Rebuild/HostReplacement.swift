import Foundation

/// When to end a host older than the app, across the welcomes that judge it.
///
/// A welcome that finds the host stale but busy leaves it waiting rather than
/// dropping it: the app keeps watching what the host says, and once nothing has
/// been running or moving for `quiet` it asks for a fresh welcome, whose `busy`
/// decides as it does at open. The app's own reading only says when to ask.
/// It can't see a send the host has taken and not yet started, or an agent's
/// report the CLI still owes a turn to; the host's `busy` can.
public struct HostReplacement: Sendable {

    public static let quiet: TimeInterval = 30

    /// The last host pid a replace was attempted for, so a welcome that arrives
    /// again — the reconnect after the kill, a reconcile — doesn't fire a
    /// second time at the same process.
    public private(set) var replacedPID: Int?
    /// The signature of the host that replace ended, so the one that comes
    /// back is judged against it — the same host coming back means the bundle
    /// on disk is not this app's, and killing it again gets it again.
    public private(set) var replacedSignature: String?

    /// Stale and holding work, so to be replaced once it isn't.
    public private(set) var isWaiting = false

    private var askedAt: Date?
    private var lastAskedAt: Date?

    public init() {}

    /// Whether to end the host that just said this. `workSentAt` is when the
    /// app last handed the host something to run: one sent after the welcome
    /// was asked for reached the host after its `busy` was taken.
    /// `appHoldsWork` is what the app has the host doing that `busy` can't
    /// show, such as a login, and holds it off the same way.
    public mutating func welcomed(
        pid: Int?,
        appBuild: String?,
        hostBuild: String?,
        sdk: HostSDK?,
        busy: Bool?,
        workSentAt: Date? = nil,
        appHoldsWork: Bool = false
    ) -> Bool {
        let asked = askedAt
        askedAt = nil
        guard let pid, pid != replacedPID,
            HostStaleness.shouldReplace(
                appBuild: appBuild, hostBuild: hostBuild, sdk: sdk, busy: false,
                afterReplacing: replacedSignature
            ),
            let busy
        else {
            isWaiting = false
            return false
        }
        let sentSinceAsking = asked.flatMap { asked in workSentAt.map { $0 >= asked } } ?? false
        guard !busy, !sentSinceAsking, !appHoldsWork else {
            isWaiting = true
            return false
        }
        isWaiting = false
        replacedPID = pid
        replacedSignature = HostStaleness.signature(hostBuild: hostBuild, sdk: sdk)
        return true
    }

    /// When to ask the waiting host for a fresh welcome: `quiet` after the
    /// last thing that moved and after the last time it was asked. Nil while
    /// not waiting or while the app can see work.
    public func nextAsk(holdsWork: Bool, lastMoved: Date?) -> Date? {
        guard isWaiting, !holdsWork else { return nil }
        let since = [lastMoved, lastAskedAt].compactMap { $0 }.max() ?? .distantPast
        return since.addingTimeInterval(Self.quiet)
    }

    /// When to look again, which is never nil while waiting: some of what
    /// holds the host ends without the app being told, such as a held login
    /// running out.
    public func nextCheck(holdsWork: Bool, lastMoved: Date?, now: Date = Date()) -> Date? {
        guard isWaiting else { return nil }
        let recheck = now.addingTimeInterval(Self.quiet)
        return nextAsk(holdsWork: holdsWork, lastMoved: lastMoved).map { min($0, recheck) } ?? recheck
    }

    public mutating func asked(at date: Date = Date()) {
        askedAt = date
        lastAskedAt = date
    }
}
