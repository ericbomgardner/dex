import DexCore
import SwiftUI

package struct MarkdownText: View {
    let blocks: [MarkdownBlock]
    var tint: ProseTint = .primary

    package init(blocks: [MarkdownBlock]) {
        self.blocks = blocks
    }

    init(blocks: [MarkdownBlock], tint: ProseTint) {
        self.blocks = blocks
        self.tint = tint
    }

    /// Prose that runs together is laid out together, since a selection can only
    /// cross characters that share a layout. What is left — a slab, a table, a
    /// quote — is drawn as itself and crossed whole.
    private enum Piece {
        case prose([MarkdownBlock])
        case block(MarkdownBlock)

        var startsWithHeading: Bool {
            if case .prose(let blocks) = self, case .heading = blocks.first { return true }
            return false
        }
    }

    private var pieces: [Piece] {
        var pieces: [Piece] = []
        var run: [MarkdownBlock] = []

        func flush() {
            guard !run.isEmpty else { return }
            pieces.append(.prose(run))
            run = []
        }

        for block in blocks {
            if ProseMarkup.flows(block) {
                run.append(block)
            } else {
                flush()
                pieces.append(.block(block))
            }
        }
        flush()
        return pieces
    }

    package var body: some View {
        VStack(alignment: .leading, spacing: ChromeMetrics.blockGap) {
            ForEach(Array(pieces.enumerated()), id: \.offset) { index, piece in
                view(for: piece)
                    .selectionIndex(index)
                    .padding(.top, Self.lead(above: piece, at: index))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A heading belongs to what follows it, so it takes its extra space above
    /// rather than sitting evenly between two paragraphs. Inside a run the
    /// paragraph style carries this; here it is the gap between two views.
    private static func lead(above piece: Piece, at index: Int) -> CGFloat {
        guard index > 0, piece.startsWithHeading else { return 0 }
        return ChromeMetrics.headingLead
    }

    @ViewBuilder
    private func view(for piece: Piece) -> some View {
        switch piece {
        case .prose(let blocks):
            ProseText(source: .markdown(blocks), face: ProseFace(tint: tint))
        case .block(let block):
            let (inset, inner) = Self.unwrapped(block)
            Self.drawn(inner, tint: tint)
                .padding(.leading, inset)
        }
    }

    private static func unwrapped(_ block: MarkdownBlock) -> (CGFloat, MarkdownBlock) {
        guard case .nested(let depth, let inner) = block else { return (0, block) }
        let (deeper, innermost) = unwrapped(inner)
        return (ProseMarkup.inset(depth) + deeper, innermost)
    }

    @ViewBuilder
    private static func drawn(_ block: MarkdownBlock, tint: ProseTint) -> some View {
        switch block {
        case .code(_, let text):
            MonoSlab(text: text, tint: tint)
        case .quote(let blocks):
            MarkdownQuote(blocks: blocks)
        case .table(let table):
            MarkdownTableView(table: table)
        case .rule:
            Divider()
        default:
            EmptyView()
        }
    }
}

package struct MonoSlab: View {
    let text: String
    var tint: ProseTint = .secondary

    package init(text: String, tint: ProseTint = .secondary) {
        self.text = text
        self.tint = tint
    }

    package var body: some View {
        ProseText(source: .plain(text), face: face)
            .selectionIndex(0)
            .padding(ChromeMetrics.detailInset)
            .background(
                RoundedRectangle(cornerRadius: ChromeMetrics.promptCorner, style: .continuous)
                    .fill(Color.primary.opacity(ChromeMetrics.detailTint))
                    .allowsHitTesting(false)
            )
    }

    private var face: ProseFace {
        var face = ProseFace.code
        face.tint = tint
        return face
    }
}

private struct MarkdownQuote: View {
    let blocks: [MarkdownBlock]

    @Environment(\.proseQuoteDepth) private var depth

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.glyphGap) {
            RoundedRectangle(cornerRadius: ChromeMetrics.promptRule / 2, style: .continuous)
                .fill(.quaternary)
                .frame(width: ChromeMetrics.promptRule)
            MarkdownText(blocks: blocks, tint: .secondary)
                .environment(\.proseQuoteDepth, depth + 1)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ProseQuoteDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    var proseQuoteDepth: Int {
        get { self[ProseQuoteDepthKey.self] }
        set { self[ProseQuoteDepthKey.self] = newValue }
    }
}

private struct MarkdownTableView: View {
    let table: MarkdownTable

    var body: some View {
        Grid(
            alignment: .topLeading,
            horizontalSpacing: ChromeMetrics.columnGap,
            verticalSpacing: ChromeMetrics.rowGap
        ) {
            GridRow {
                ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                    self.cell(cell, row: 0, column: column)
                        .gridColumnAlignment(alignment(at: column))
                }
            }

            Divider()
                .gridCellColumns(max(1, table.header.count))

            ForEach(Array(table.rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        self.cell(cell, row: index + 1, column: column)
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func cell(_ text: String, row: Int, column: Int) -> some View {
        ProseText(
            source: .markdown([.paragraph(text)]),
            face: ProseFace(weight: row == 0 ? .semibold : .regular),
            hugsWidth: true,
            cell: SelectionCell(row: row, column: column, markdown: text, alignment: markdownAlignment(at: column))
        )
        .selectionIndex(column)
        .selectionIndex(row)
    }

    private func markdownAlignment(at index: Int) -> MarkdownAlignment {
        table.alignments.indices.contains(index) ? table.alignments[index] : .leading
    }

    private func alignment(at index: Int) -> HorizontalAlignment {
        switch markdownAlignment(at: index) {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}
