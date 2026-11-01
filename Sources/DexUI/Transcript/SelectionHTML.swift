import AppKit

/// The selection as HTML, the flavor Slack, GitHub's comment box, Notes and
/// Mail read off the clipboard and turn into their own formatting. Built from
/// the attributes the prose was drawn with, so a partial selection inside a
/// paragraph works the same as a whole one.
enum SelectionHTML {

    static func document(_ fragments: [String]) -> String {
        "<!doctype html><html><head><meta charset=\"utf-8\"></head><body>\n"
            + fragments.joined(separator: "\n")
            + "\n</body></html>"
    }

    static func fragment(plain text: String) -> String {
        guard !text.isEmpty else { return "" }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { escaped(String($0)) }
        return "<p>" + lines.joined(separator: "<br>") + "</p>"
    }

    static func preformatted(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        return "<pre>" + escaped(text) + "</pre>"
    }

    static func fragment(_ text: NSAttributedString) -> String {
        var html: [String] = []
        var items: [Item] = []
        func closeList() {
            guard !items.isEmpty else { return }
            var index = 0
            html.append(nested(items, from: &index, level: items[0].level))
            items = []
        }
        for paragraph in paragraphs(of: text) {
            if let item = listItem(paragraph) {
                if !item.html.isEmpty { items.append(item) }
            } else {
                closeList()
                let body = inline(paragraph)
                if !body.isEmpty { html.append("<p>" + body + "</p>") }
            }
        }
        closeList()
        return html.joined(separator: "\n")
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private struct Run {
        var text: String
        let attributes: [NSAttributedString.Key: Any]
    }

    private struct Item {
        let level: Int
        let ordered: Bool
        let html: String
    }

    /// A paragraph break is the one newline drawn with no font on it; a newline
    /// inside a paragraph keeps the paragraph's font and reads as a hard break.
    private static func paragraphs(of text: NSAttributedString) -> [[Run]] {
        var out: [[Run]] = [[]]
        let whole = text.string as NSString
        text.enumerateAttributes(in: NSRange(location: 0, length: text.length)) { attributes, range, _ in
            let piece = whole.substring(with: range)
            if attributes[.font] == nil, !piece.isEmpty, piece.allSatisfy({ $0 == "\n" }) {
                for _ in piece { out.append([]) }
            } else {
                out[out.count - 1].append(Run(text: piece, attributes: attributes))
            }
        }
        return out
    }

    /// A list item is known by its paragraph style — the text hangs past the
    /// marker — rather than by the marker itself, which a selection can start
    /// part way through. What is left of the tab, marker, tab prefix is dropped.
    private static func listItem(_ runs: [Run]) -> Item? {
        guard let style = runs.first?.attributes[.paragraphStyle] as? NSParagraphStyle,
              style.headIndent > style.firstLineHeadIndent
        else { return nil }
        let level = Int((style.firstLineHeadIndent / ChromeMetrics.listIndent).rounded())

        let string = runs.map(\.text).joined()
        var prefix = string.startIndex
        if string[prefix...].hasPrefix("\t") { prefix = string.index(after: prefix) }
        var marker: String?
        if let tab = string[prefix...].firstIndex(of: "\t"), isMarker(string[prefix..<tab]) {
            marker = String(string[prefix..<tab])
            prefix = string.index(after: tab)
        }

        var remaining = string.distance(from: string.startIndex, to: prefix)
        var rest: [Run] = []
        for var run in runs {
            if remaining > 0 {
                let cut = min(remaining, run.text.count)
                run.text = String(run.text.dropFirst(cut))
                remaining -= cut
            }
            if !run.text.isEmpty { rest.append(run) }
        }
        return Item(level: level, ordered: marker?.first?.isNumber == true, html: inline(rest))
    }

    private static func isMarker(_ text: Substring) -> Bool {
        guard !text.isEmpty, text.count <= 4 else { return false }
        if text.count == 1, "•-*+".contains(text) { return true }
        return text.allSatisfy { $0.isNumber || $0 == "." }
    }

    /// Items at a deeper level nest inside the item before them; a change of
    /// kind at the same level closes the list and opens another.
    private static func nested(_ items: [Item], from index: inout Int, level: Int) -> String {
        let tag = items[index].ordered ? "ol" : "ul"
        var out = "<\(tag)>"
        while index < items.count, items[index].level >= level {
            let item = items[index]
            if item.level == level, (item.ordered ? "ol" : "ul") != tag {
                return out + "</\(tag)>" + nested(items, from: &index, level: level)
            }
            out += "<li>" + item.html
            index += 1
            if index < items.count, items[index].level > level {
                out += nested(items, from: &index, level: items[index].level)
            }
            out += "</li>"
        }
        return out + "</\(tag)>"
    }

    private static func inline(_ runs: [Run]) -> String {
        runs.map { run in
            var html = escaped(run.text).replacingOccurrences(of: "\n", with: "<br>")
            guard !html.trimmingCharacters(in: .whitespaces).isEmpty else { return html }
            let font = run.attributes[.font] as? NSFont
            let traits = font?.fontDescriptor.symbolicTraits ?? []
            if font?.isFixedPitch == true || traits.contains(.monoSpace) { html = "<code>\(html)</code>" }
            if traits.contains(.bold) || isHeavy(font) { html = "<b>\(html)</b>" }
            if traits.contains(.italic) { html = "<i>\(html)</i>" }
            if run.attributes[.strikethroughStyle] != nil { html = "<s>\(html)</s>" }
            if let link = run.attributes[.link] {
                let href = (link as? URL)?.absoluteString ?? "\(link)"
                html = "<a href=\"\(escaped(href))\">\(html)</a>"
            }
            return html
        }.joined()
    }

    /// A semibold system font carries no bold trait, only a weight, and that is
    /// what headings are drawn in.
    private static func isHeavy(_ font: NSFont?) -> Bool {
        guard let traits = font?.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any],
              let weight = traits[.weight] as? CGFloat
        else { return false }
        return weight >= NSFont.Weight.semibold.rawValue
    }
}
