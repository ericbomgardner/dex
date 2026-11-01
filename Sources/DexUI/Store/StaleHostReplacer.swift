import DexCore
import Foundation
import Observation

/// Ends this Mac's host when the app is newer than it and it is holding
/// nothing, so `HostClient` brings one up from this bundle. One that is busy
/// when judged is watched and replaced once it isn't.
@MainActor
@Observable
final class StaleHostReplacer {
    @ObservationIgnored private let host: HostSessions
    @ObservationIgnored private let rebuilder: Rebuilder
    @ObservationIgnored private let appBuildCommit: String?
    private var state = HostReplacement()
    @ObservationIgnored private var askTask: Task<Void, Never>?

    init(host: HostSessions, rebuilder: Rebuilder, appBuildCommit: String?) {
        self.host = host
        self.rebuilder = rebuilder
        self.appBuildCommit = appBuildCommit
    }

    /// A stale host is being kept only until its sessions finish.
    var isWaiting: Bool { state.isWaiting && host.isRunning }

    /// The app is newer than the host it just heard a welcome from, and the
    /// host says it is holding nothing, so end it and let `HostClient` bring
    /// one up from this bundle. This is the installed-copy path: swap the
    /// `.app`, open it, and the old host still holding the socket is stopped
    /// here rather than by a menu that only a checkout has.
    ///
    /// Synchronous off the welcome: `host.hostBusy` is the host's own reading,
    /// taken as it built the welcome, so it doesn't race the `session.tasks`
    /// levels that arrive behind it. The pid dedup is set before the kill and
    /// there is no suspension between the check and it, so two welcomes for one
    /// pid can't both act.
    func replaceIfStale() {
        guard !rebuilder.isRunning else { return }
        guard state.welcomed(
            pid: host.pid,
            appBuild: appBuildCommit,
            hostBuild: host.hostBuild,
            sdk: host.sdk,
            busy: host.hostBusy,
            workSentAt: host.lastWorkSent,
            appHoldsWork: host.holdsWork()
        ) else { return }
        host.killForReplacement()
    }

    /// Off every change the host reports and every piece of work begun or
    /// ended. While waiting there is always a check pending, so a wait never
    /// rests on a change that might not come.
    func hostChanged() {
        guard let next = state.nextCheck(holdsWork: host.holdsWork(), lastMoved: host.lastMoved) else {
            askTask?.cancel()
            askTask = nil
            return
        }
        schedule(at: next)
    }

    private func schedule(at due: Date) {
        askTask?.cancel()
        askTask = Task { [weak self] in
            let wait = due.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.askIfStillQuiet()
        }
    }

    private func askIfStillQuiet() {
        askTask = nil
        let now = Date()
        let holdsWork = host.holdsWork(now: now)
        guard let next = state.nextCheck(holdsWork: holdsWork, lastMoved: host.lastMoved, now: now) else { return }
        guard host.isRunning, !rebuilder.isRunning, !holdsWork else {
            return schedule(at: now.addingTimeInterval(HostReplacement.quiet))
        }
        if next > now { return schedule(at: next) }
        state.asked(at: now)
        host.askForWelcome()
        hostChanged()
    }
}
