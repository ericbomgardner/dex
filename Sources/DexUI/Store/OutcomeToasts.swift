import DexCore
import Foundation
import Observation

/// The one toast under the list, which row actions and the host's refusals
/// report through. One slot: a newer report replaces the one showing.
@MainActor
@Observable
final class OutcomeToasts {
    private(set) var lastOutcome: ActionOutcome?

    private var outcomeToken = 0
    private var outcomeDismissTask: Task<Void, Never>?

    func clear() { report(nil) }

    /// A refused request in the host's own words. The pickers keep it from
    /// happening over a mode, so what reaches here is a host that has moved
    /// under us — worth a sentence about the restart rather than a shrug.
    /// Named by the caller rather than assumed. This was written for the mode
    /// dial and had its label baked in, so every other refusal that came through
    /// it — a send, and later an effort — reported itself as a permission mode.
    func hostRefused(_ subject: String, _ what: String, because why: String) {
        report(ActionOutcome(
            label: subject,
            succeeded: false,
            message: "the host refused \(what) — \(why)"
        ))
    }

    func report(_ reported: ActionOutcome?) {
        let outcome = reported?.shouldBeShown == true ? reported : nil
        outcomeDismissTask?.cancel()
        outcomeToken += 1
        let token = outcomeToken
        lastOutcome = outcome

        guard let dwell = outcome?.dwell else { return }
        outcomeDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(dwell))
            guard !Task.isCancelled, let self, self.outcomeToken == token else { return }
            self.lastOutcome = nil
        }
    }
}
