import AppKit

/// The selection as markdown, for the plain-text flavor of the clipboard: a
/// terminal, an editor or a prompt gets the list and the code back rather than
/// the bullets and tab stops they were drawn with. Read from the same
/// attributes `SelectionHTML` reads, so a partial selection works the same.
enum SelectionMarkdown {

    static func fragment(_ text: NSAttributedString) -> String {
        var blocks: [String] = []
        var items: [String] = []
        var kinds: [Int: Bool] = [:]
        var widths: [Int: Int] = [:]
        func closeList() {
            guard !items.isEmpty else { return }
            blocks.append(items.joined(separator: "\n"))
            items = []
            kinds = [:]
            widths = [:]
        }
        /// Where text inside an item at `level` starts: past every marker
        /// above it, so a `10.` parent gets the four columns it needs.
        func column(_ level: Int) -> String {
            String(repeating: " ", count: (0..<level).reduce(0) { $0 + (widths[$1] ?? 2) })
        }
        for paragraph in SelectionHTML.paragraphs(of: text) {
            if let (level, marker, rest) = SelectionHTML.listParts(paragraph) {
                let body = inline(rest)
                guard !body.isEmpty else { continue }
                let ordered = marker?.first?.isNumber == true
                if kinds[level].map({ $0 != ordered }) == true { closeList() }
                kinds = kinds.filter { $0.key < level }
                kinds[level] = ordered
                let bullet = ordered ? marker ?? "-" : "-"
                widths = widths.filter { $0.key < level }
                widths[level] = bullet.count + 1
                items.append(column(level) + bullet + " " + body)
            } else if let depth = insideAnItem(paragraph) {
                var body = inline(paragraph).trimmingCharacters(in: .whitespaces)
                guard !body.isEmpty else { continue }
                if let level = headingLevel(paragraph) { body = String(repeating: "#", count: level) + " " + body }
                let indent = column(depth)
                let indented = body.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { indent + $0 }.joined(separator: "\n")
                if items.isEmpty { blocks.append(body) } else { items.append("\n" + indented) }
            } else {
                closeList()
                if let level = headingLevel(paragraph) {
                    let body = inline(paragraph).trimmingCharacters(in: .whitespaces)
                    if !body.isEmpty { blocks.append(String(repeating: "#", count: level) + " " + body) }
                } else {
                    let body = inline(paragraph)
                    if !body.isEmpty { blocks.append(body) }
                }
            }
        }
        closeList()
        return blocks.joined(separator: "\n\n")
    }

    static func quoted(_ text: String, depth: Int) -> String {
        guard depth > 0, !text.isEmpty else { return text }
        let mark = String(repeating: ">", count: depth)
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? mark : mark + " " + $0 }
            .joined(separator: "\n")
    }

    static func fenced(_ code: String) -> String {
        guard !code.isEmpty else { return "" }
        var fence = "```"
        while code.contains(fence) { fence += "`" }
        return fence + "\n" + code + "\n" + fence
    }

    /// A paragraph set in from the margin with no bullet hanging out of it is
    /// one an item holds past its first.
    private static func insideAnItem(_ runs: [SelectionHTML.Run]) -> Int? {
        guard let style = runs.first?.attributes[.paragraphStyle] as? NSParagraphStyle,
              style.firstLineHeadIndent > 0, style.headIndent == style.firstLineHeadIndent
        else { return nil }
        let past = style.firstLineHeadIndent - ChromeMetrics.bulletSlot - ChromeMetrics.iconGap
        return max(0, Int((past / ChromeMetrics.listIndent).rounded())) + 1
    }

    private static func headingLevel(_ runs: [SelectionHTML.Run]) -> Int? {
        runs.lazy.compactMap { $0.attributes[.proseHeading] as? Int }.first
    }

    /// Headings and table headers are set semibold, which carries the bold
    /// trait without being bold anyone wrote.
    private static func weight(_ font: NSFont) -> CGFloat {
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        return traits?[.weight] as? CGFloat ?? 0
    }

    private static func inline(_ runs: [SelectionHTML.Run]) -> String {
        runs.map { run in
            let font = run.attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            var text = run.text
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return text }
            if font?.isFixedPitch == true || traits.contains(.monoSpace) { text = wrapped(text, in: "`") }
            if let font, weight(font) >= NSFont.Weight.bold.rawValue - 0.05 { text = wrapped(text, in: "**") }
            if traits.contains(.italic) { text = wrapped(text, in: "*") }
            if run.attributes[.strikethroughStyle] != nil { text = wrapped(text, in: "~~") }
            if let link = run.attributes[.link] {
                let href = (link as? URL)?.absoluteString ?? "\(link)"
                text = "[\(text)](\(href))"
            }
            return text
        }.joined()
    }

    /// `** bold**` is not bold, so the spaces a run starts or ends with go
    /// outside the marks.
    private static func wrapped(_ text: String, in mark: String) -> String {
        let leading = text.prefix { $0 == " " }
        let trailing = text.reversed().prefix { $0 == " " }
        let core = text.dropFirst(leading.count).dropLast(trailing.count)
        let markers = mark == "`" && core.contains("`") ? "``" : mark
        return leading + markers + core + markers + String(trailing)
    }
}
