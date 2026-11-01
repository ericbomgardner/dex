import DexCore
import AppKit
import Foundation
import Observation

/// The sessions currently let onto the pointer or keyboard, and the poller
/// that takes a grant down once its session has stopped driving.
@MainActor
@Observable
final class ScreenTakeovers {
    /// By host key. Kept here rather than read off the asks: an ask is answered
    /// and gone, and the bar has to stand for the rest of the turn.
    private(set) var byKey: [String: ScreenTakeover] = [:]
    /// The call each grant's newest drive came from, once the transcript shows it.
    @ObservationIgnored private var drives: [String: String] = [:]

    @ObservationIgnored private let host: HostSessions
    @ObservationIgnored private let presenter: NotificationPresenter
    @ObservationIgnored private let preferences: Preferences
    @ObservationIgnored private let transcripts: TranscriptLocator

    /// The list row for a host key.
    @ObservationIgnored var row: (String) -> SessionRowModel? = { _ in nil }
    /// The host holding a key, which is this Mac's unless another's is.
    @ObservationIgnored var holder: (String) -> HostSessions
    /// A grant came down, so its notice can go.
    @ObservationIgnored var onEnded: () -> Void = {}

    init(
        host: HostSessions,
        presenter: NotificationPresenter,
        preferences: Preferences,
        transcripts: TranscriptLocator
    ) {
        self.host = host
        self.presenter = presenter
        self.preferences = preferences
        self.transcripts = transcripts
        self.holder = { _ in host }
    }

    var keys: Dictionary<String, ScreenTakeover>.Keys { byKey.keys }

    /// Oldest first, for the bar.
    var list: [ScreenTakeover] {
        byKey.values.sorted { $0.since < $1.since }
    }

    func name(of takeover: ScreenTakeover) -> String {
        guard let row = row(takeover.key) else {
            return "A session"
        }
        return row.session.chosenName ?? row.session.folderName
    }

    /// The bar's Stop: ends the turn, which is what the takeover was granted
    /// for, and the drive itself where it outlives the turn. The bar comes down
    /// on the status change or the lapse that follows.
    func stop(_ takeover: ScreenTakeover) {
        host.interrupt(key: takeover.key)
        if let task = runningDrive(takeover.key) {
            holder(takeover.key).stopTask(key: takeover.key, taskId: task.taskId)
        }
    }

    func statusChanged(_ key: String, to state: HostSessionState) {
        if ScreenTakeoverPolicy.endsTakeover(state, driveStillRunning: runningDrive(key) != nil) {
            ended(key)
        }
    }

    private func runningDrive(_ key: String) -> HostTask? {
        guard let id = drives[key] else { return nil }
        return holder(key).tasks(key: key)[id]
    }

    /// Let through on the app's own word when nobody is at the keyboard, or
    /// when this session already has the screen for this turn. Otherwise the
    /// ask stands and the card answers it.
    func decide(_ ask: HostAsk) {
        let decision = ScreenTakeoverPolicy.decide(
            idleFor: InputIdle.seconds(),
            alreadyDriving: byKey[ask.key] != nil
        )
        guard decision == .allow, let allow = ask.options.first(where: { $0.kind.isAllow })
        else { return }
        host.answer(askId: ask.askId, option: allow)
    }

    func began(_ ask: HostAsk) {
        let doing = HostAskContent.read(ask).permissionRequest?.drivingLine
        let since = byKey[ask.key]?.since
        byKey[ask.key] = ScreenTakeover(
            key: ask.key,
            since: since ?? Date(),
            lastDrove: Date(),
            command: ask.input.objectValue?["command"]?.stringValue,
            doing: doing
        )
        if since == nil { watchForLapse(ask.key) }
        // Once per turn, not per click: the bar carries the rest.
        guard since == nil, preferences.postsNotifications,
              let row = row(ask.key)
        else { return }
        presenter.post(SessionTransitions.takeoverDraft(for: row, doing: doing))
    }

    func ended(_ key: String) {
        drives[key] = nil
        guard byKey.removeValue(forKey: key) != nil else { return }
        onEnded()
    }

    /// Takes the bar down once the session has stopped driving without its
    /// turn ending. A transcript not found yet keeps the old rule: the bar
    /// stands until the turn ends.
    private func watchForLapse(_ key: String) {
        let sessionID = row(key)?.session.sessionId
        let transcripts = self.transcripts
        Task { [weak self] in
            var tail: TranscriptTail?
            var returns = DriveReturns()
            // The first read goes at once: it fixes where the tail starts, and a
            // screenshot read back in the next few seconds can be hundreds of
            // kilobytes that would push the drive's own call out of reach.
            var first = true
            while true {
                if !first { try? await Task.sleep(for: .seconds(5)) }
                first = false
                guard let self, self.byKey[key] != nil else { return }

                let reading = await Task.detached(priority: .utility) { [tail, returns] in
                    var tail = tail ?? transcripts.locate(sessionID: sessionID).map {
                        // From a little before the grant: the drive's own call can
                        // be flushed on either side of the allow.
                        TranscriptTail(url: $0, offset: Self.offset(before: $0))
                    }
                    var returns = returns
                    if let lines = tail?.read().lines { returns.read(lines) }
                    return (tail, returns)
                }.value
                (tail, returns) = reading

                // Asked again after the read: a drive allowed while it was out
                // moved the grant on, and deciding on the old one would end it.
                guard let takeover = self.byKey[key] else { return }
                guard let command = takeover.command,
                      let drive = returns.call(running: command)
                else { continue }
                self.drives[key] = drive.id
                // A drive the session backgrounded comes back at once and
                // keeps clicking; the host still lists it.
                let running = self.holder(key).tasks(key: key)[drive.id] != nil
                if ScreenTakeoverPolicy.hasLapsed(
                    takeover, returnedAt: drive.returnedAt, stillRunning: running, now: Date()
                ) {
                    self.ended(key)
                    return
                }
            }
        }
    }

    nonisolated private static func offset(before url: URL) -> UInt64 {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        return size > 256_000 ? size - 256_000 : 0
    }
}
