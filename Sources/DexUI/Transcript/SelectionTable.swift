import DexCore

/// Where a run of prose sits in a table. Each cell is a piece of its own, so a
/// drag can take characters out of one; this is what lets a drag through
/// several be put back together as a table rather than a stack of paragraphs.
package struct SelectionCell: Hashable {
    /// The header is row 0.
    let row: Int
    let column: Int
    let markdown: String
    let alignment: MarkdownAlignment
}

/// The cells one selection took out of one table, copied as markdown for a
/// plain-text field and as a `<table>` for a spreadsheet.
///
/// The header goes along whole whether or not the drag reached it: a markdown
/// table isn't one without it, and half a column's name names nothing. A cell in a taken row that the drag
/// didn't cover goes empty, so every row keeps its columns.
@MainActor
struct SelectionTable {

    struct Piece {
        let region: any SelectionRegion
        let cell: SelectionCell
        let range: Range<Int>?
    }

    /// Every cell of the table, taken or not, since the header is read off the
    /// cells the drag never reached.
    let pieces: [Piece]

    private var columns: Int { (pieces.map(\.cell.column).max() ?? -1) + 1 }

    private var header: [Piece?] { row(0) }

    /// Every row from the first the drag reached to the last, since a row of
    /// empty cells has no characters for it to reach.
    private var taken: [[Piece?]] {
        let reached = pieces.filter { $0.range != nil && $0.cell.row > 0 }.map(\.cell.row)
        guard let first = reached.min(), let last = reached.max() else { return [] }
        return (first...last).map(row)
    }

    private func row(_ index: Int) -> [Piece?] {
        (0..<columns).map { column in
            pieces.first { $0.cell.row == index && $0.cell.column == column }
        }
    }

    var markdown: String {
        func line(_ cells: [String]) -> String { "| " + cells.joined(separator: " | ") + " |" }

        let rule = header.map { piece -> String in
            switch piece?.cell.alignment ?? .leading {
            case .leading: "---"
            case .center: ":---:"
            case .trailing: "---:"
            }
        }
        let names = header.map { piece in piece.map { markdown(of: $0, headed: true) } ?? "" }
        let rows = taken.map { $0.map { piece in piece.map { markdown(of: $0, headed: false) } ?? "" } }
        return ([line(names), line(rule)] + rows.map(line)).joined(separator: "\n")
    }

    var html: String {
        func line(_ cells: [String], _ tag: String) -> String {
            "<tr>" + cells.map { "<\(tag)>\($0)</\(tag)>" }.joined() + "</tr>"
        }
        let names = header.map { piece in piece.map { html(of: $0, headed: true) } ?? "" }
        let rows = taken.map { $0.map { piece in piece.map { html(of: $0, headed: false) } ?? "" } }
        return "<table><thead>" + line(names, "th") + "</thead><tbody>"
            + rows.map { line($0, "td") }.joined() + "</tbody></table>"
    }

    /// What the cell was written as when all of it is taken, so code and links
    /// survive the trip; the characters on screen when only some are.
    private func markdown(of piece: Piece, headed: Bool) -> String {
        if headed { return piece.cell.markdown }
        guard let range = piece.range else { return "" }
        if range == 0..<piece.region.selectionLength { return piece.cell.markdown }
        return piece.region.selectionText(in: range)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
    }

    /// Without the paragraph the prose wraps itself in: a `<p>` in a cell is a
    /// line break in some spreadsheets.
    private func html(of piece: Piece, headed: Bool) -> String {
        guard let range = headed ? 0..<piece.region.selectionLength : piece.range else { return "" }
        var html = piece.region.selectionHTML(in: range)
        if html.hasPrefix("<p>"), html.hasSuffix("</p>") {
            html = String(html.dropFirst(3).dropLast(4))
        }
        return html
    }
}
