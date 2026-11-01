import DexCore
import Foundation
import Observation
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "dispatch")

/// What the app is holding for sessions it has asked the host for and not yet
/// seen: the rows that stand in until the list catches up, the messages a
/// resume is carrying, and what each session was launched as.
///
/// The asking itself is the store's (`SessionStore+Dispatch.swift`): it
/// reads the composer, the archive and which machine a key is on.
@MainActor
@Observable
final class DispatchController {
    private(set) var pending: [PendingDispatch] = []

    /// What each hosted session was launched as, by key. Read by the pane for
    /// the beat before init has named the model.
    private(set) var launchedModels: [String: SessionModel] = [:]

    /// What a resume is holding until the session it asked for is up: the
    /// message that started it, and anything typed while it was on its way.
    private struct ResumeInFlight {
        var text: String
        var pending: [String] = []
    }

    private var resuming: [String: ResumeInFlight] = [:]

    @ObservationIgnored private let pane: SessionPane
    @ObservationIgnored private let toasts: OutcomeToasts

    /// A pending dispatch learned its key, and what it was started with can
    /// stand in as the row's second line.
    @ObservationIgnored var onBound: (_ rowID: String, _ opening: SessionDigest) -> Void = { _, _ in }

    init(pane: SessionPane, toasts: OutcomeToasts) {
        self.pane = pane
        self.toasts = toasts
    }

    var boundRowIDs: [String] { pending.compactMap(\.rowID) }

    func launched(_ key: String, as model: SessionModel) {
        launchedModels[key] = model
    }

    // The rows that stand in

    /// The row does not exist until the host says it does, and a composer
    /// that just empties itself reads as a message sent into the void.
    func hold(_ dispatch: PendingDispatch) {
        pending.append(dispatch)
        pane.start(dispatch)
        toasts.report(nil)
        expire(dispatch.id)
    }

    func bind(rowID: String?, to id: UUID) {
        guard let rowID, let index = pending.firstIndex(where: { $0.id == id })
        else { return }
        pending[index].rowID = rowID
        onBound(rowID, SessionDigest(lastMessage: pending[index].opening))
    }

    func drop(_ id: UUID) {
        pending.removeAll { $0.id == id }
        pane.stopStarting(id)
    }

    struct Claims {
        /// The ones a pane was waiting on, which it opens.
        var claimed: [(dispatch: PendingDispatch, row: SessionRowModel)] = []
        /// The last to land, for the list to scroll to when no pane was waiting.
        var arrived: (dispatch: PendingDispatch, row: SessionRowModel)?
    }

    /// Hands each pending dispatch whose row has arrived over to it.
    func claim(in rows: [SessionRowModel]) -> Claims? {
        guard !pending.isEmpty else { return nil }

        var unclaimed = rows
        var stillWaiting: [PendingDispatch] = []
        var claims = Claims()

        for dispatch in pending {
            guard let row = dispatch.matchingRow(in: unclaimed) else {
                stillWaiting.append(dispatch)
                continue
            }
            unclaimed.removeAll { $0.rowID == row.rowID }

            // Every arrival, not just the pane's: one it isn't waiting on would
            // otherwise leave it waiting on a session that is already here.
            if pane.starting?.id == dispatch.id { claims.claimed.append((dispatch, row)) }
            pane.stopStarting(dispatch.id)
            claims.arrived = (dispatch, row)
        }

        pending = stillWaiting
        return claims
    }

    /// A session that goes before it ever becomes a row. Nothing else settles
    /// the place held for it: the pending dispatch is waiting on a row, and one
    /// that died on the way up produces none — so it sat there for its twenty
    /// seconds and then blamed the list for being slow.
    func dispatchFailed(_ key: String, because reason: String) {
        // The host's two words for a session that closed itself rather than
        // failed. A place still held when one of those arrives is the list being
        // slow, which is what the wait already says when it runs out.
        guard reason != "ended", reason != "retired" else { return }
        guard let dispatch = pending.first(where: { $0.rowID == key }) else { return }
        drop(dispatch.id)
        toasts.report(ActionOutcome(
            label: "New session",
            succeeded: false,
            message: "it never came up — \(reason)"
        ))
    }

    private func expire(_ id: UUID) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PendingDispatch.patience))
            guard let self, let dispatch = self.pending.first(where: { $0.id == id }),

                  dispatch.hasExpired()
            else { return }
            self.drop(id)
            logger.notice("dispatched \(dispatch.rowID ?? "?", privacy: .public) never appeared in the list")
            self.toasts.report(ActionOutcome(
                label: "New session",
                succeeded: true,
                message: dispatch.rowID.map { "started \($0) — the list hasn't picked it up" }
                    ?? "started, but the list hasn't picked it up",
                isReadout: true
            ))
        }
    }

    // Resumes

    /// False when one is already on its way for the key, which `text` now
    /// waits behind. A second message before the first is up must not start a
    /// second session: the host refuses the key it is already running, and
    /// the app would report the refusal as the resume having failed.
    func beginResume(_ key: String, saying text: String) -> Bool {
        guard resuming[key] == nil else {
            resuming[key]?.pending.append(text)
            return false
        }
        resuming[key] = ResumeInFlight(text: text)
        return true
    }

    /// A resumed session is up once the host has named its transcript.
    /// Answers anything typed while it was coming up, in the order it was
    /// typed, for the caller to say now.
    func resumeArrived(_ key: String) -> [String]? {
        resuming.removeValue(forKey: key)?.pending
    }

    /// Said rather than swallowed, and the message handed back: the composer
    /// clears as you send, so a failure nobody mentions is a message you wrote,
    /// watched leave, and will write again.
    func resumeFailed(_ key: String, because reason: String) {
        guard let flight = resuming.removeValue(forKey: key) else { return }
        toasts.report(ActionOutcome(label: "Resume", succeeded: false, message: reason))
        let handed = [flight.text] + flight.pending
        pane.restore(draft: handed.joined(separator: "\n"), for: key, unsaying: handed)
    }

    /// A resume that neither comes up nor fails is a host that stopped talking
    /// mid-request. Nothing else would ever release the message.
    func expireResume(_ key: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            guard let self, self.resuming[key] != nil else { return }
            self.resumeFailed(key, because: "the host never picked that session up")
        }
    }
}
