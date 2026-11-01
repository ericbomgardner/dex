import Foundation

/// How far the ask card may grow before the question inside it starts scrolling.
public enum AskCardHeight {

    /// The card never claims more than this much of the pane it sits at the foot
    /// of. The rest is the conversation the question was raised out of, which is
    /// most of what there is to answer it from.
    private static let share: Double = 0.6

    /// Below this a question and an option can't be read together, so a short
    /// pane gives the card more than its share rather than a slot nothing fits
    /// in.
    private static let floor: CGFloat = 120

    /// How tall the question is drawn: its own height, until the card would
    /// claim more of the column than its share.
    ///
    /// `chrome` is what the card draws around the question — the heading and its
    /// arrows, the dots and the send — which stays put while the question
    /// scrolls under it, and so comes out of the share first.
    ///
    /// An unmeasured column bounds nothing: the card is drawn before the pane
    /// has been measured, and a share of nothing would collapse it.
    public static func questionHeight(columnHeight: CGFloat,
                                      chrome: CGFloat,
                                      natural: CGFloat) -> CGFloat {
        guard columnHeight > 0 else { return natural }
        return min(natural, max(columnHeight * share - chrome, floor))
    }
}
