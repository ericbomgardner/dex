import DexCore
import SwiftUI

/// Lays subviews out left to right, wrapping when the next one would overhang.
struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let sizes = sizes(of: subviews, within: width)
        let lines = ChipFlow.lines(sizes: sizes, spacing: spacing, within: width)

        return CGSize(
            width: proposal.width ?? (lines.map(\.width).max() ?? 0),
            height: ChipFlow.height(of: lines, spacing: spacing)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let sizes = sizes(of: subviews, within: bounds.width)
        let lines = ChipFlow.lines(sizes: sizes, spacing: spacing, within: bounds.width)

        for (index, origin) in ChipFlow.origins(of: lines, sizes: sizes, spacing: spacing).enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                anchor: .topLeading,
                proposal: ProposedViewSize(sizes[index])
            )
        }
    }

    /// A subview is offered no more than the row it has to sit in: one too long
    /// for the width wraps inside itself rather than hanging off the end.
    private func sizes(of subviews: Subviews, within width: CGFloat) -> [CGSize] {
        subviews.map { subview in
            let ideal = subview.sizeThatFits(.unspecified)
            guard ideal.width > width else { return ideal }
            return subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
        }
    }
}
