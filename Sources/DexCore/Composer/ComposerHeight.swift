import Foundation

/// How far a composer's field may grow before it starts scrolling.
public enum ComposerHeight {

    /// The field never claims more than this much of the window column it sits in.
    private static let share: Double = 0.5

    /// A `ceiling` stops the field short of what the column would allow, for a
    /// composer with somewhere roomier to send long text — without one, the
    /// column is the only bound.
    public static func maxLines(columnHeight: CGFloat,
                                lineHeight: CGFloat,
                                insets: CGFloat,
                                minLines: Int,
                                ceiling: Int = .max) -> Int {
        guard columnHeight > 0, lineHeight > 0 else { return minLines }

        let usable = columnHeight * share - insets
        let fits = Int((usable / lineHeight).rounded(.down))
        return min(max(minLines, fits), max(minLines, ceiling))
    }
}
