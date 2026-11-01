import DexCore
import SwiftUI

/// Everything a hosted session is holding out, wherever the pane wants it.
///
/// Scoped to one session: the queue spans every session the host is running, so
/// a question raised by one must not appear over another's transcript.
struct HostAskOverlay: View {
    /// The session the pane is showing, by the host's key for it.
    let key: String?
    /// One the pane is already answering, which would otherwise be answerable in
    /// two places at once.
    var excluding: String?
    /// Height of the pane the card is drawn at the foot of, which bounds it.
    let columnHeight: CGFloat
    /// The page the card is on, which the composer under it answers.
    @Binding var reading: String?
    /// What has been written into the questions and not yet sent, kept by the
    /// store so it survives the card being built again for another session.
    @Binding var drafts: AskDrafts
    let host: HostSessions

    var body: some View {
        let mine = host.asks.pending.filter {
            (key == nil || $0.key == key) && $0.askId != excluding
        }

        if !mine.isEmpty {
            AskCard(
                asks: mine,
                columnHeight: columnHeight,
                onAnswerQuestion: { host.answer(askId: $0, answers: $1, notes: $2) },
                onAnswerPermission: { host.answer(askId: $0, option: $1) },
                reading: $reading,
                drafts: $drafts
            )
            // Identity is the session rather than the ask it is showing: a
            // second ask arriving appends pages to the run, and a fresh card
            // would throw away the answers already written into it.
            .id(key ?? "")
            .transition(.opacity)
        }
    }
}
