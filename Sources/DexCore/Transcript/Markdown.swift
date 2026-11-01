import Foundation

public enum MarkdownAlignment: Sendable, Hashable {
    case leading
    case center
    case trailing
}

public struct MarkdownListItem: Sendable, Hashable {
    public let level: Int
    public let marker: String?
    public let text: String

    public init(level: Int, marker: String?, text: String) {
        self.level = level
        self.marker = marker
        self.text = text
    }
}

public struct MarkdownTable: Sendable, Hashable {
    public let header: [String]
    public let alignments: [MarkdownAlignment]
    public let rows: [[String]]

    public init(header: [String], alignments: [MarkdownAlignment], rows: [[String]]) {
        self.header = header
        self.alignments = alignments
        self.rows = rows
    }
}

/// One piece of a reply, split so the view can lay each kind out on its own.
/// Text inside a block keeps its inline markup — `Text` understands that much
/// already, and this parser has no business rewriting it.
public indirect enum MarkdownBlock: Sendable, Hashable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list([MarkdownListItem])
    case code(language: String?, text: String)
    case quote([MarkdownBlock])
    case table(MarkdownTable)
    case rule
    /// A block inside a list item: a second paragraph, a slab of code, a
    /// quote. The list is ended before it and picked up after it, so nesting
    /// is one level of inset rather than a tree; `depth` is the item's level
    /// plus one.
    case nested(depth: Int, MarkdownBlock)
}

public enum Markdown {
    public static func blocks(in text: String) -> [MarkdownBlock] {
        blocks(in: text, depth: 0)
    }

    fileprivate static func blocks(in text: String, depth: Int) -> [MarkdownBlock] {
        var parser = Parser(lines: text.components(separatedBy: "\n"), depth: depth)
        return parser.run()
    }
}

private struct Parser {
    let lines: [String]
    /// How many quotes and items this sits inside. Past `deepest` a quote is
    /// left as text: `>` runs into the thousands in a pasted separator, and
    /// each one would be a frame on the stack.
    let depth: Int
    static let deepest = 8
    var index = 0
    var blocks: [MarkdownBlock] = []

    mutating func run() -> [MarkdownBlock] {
        while index < lines.count {
            let line = lines[index]

            if blank(line) {
                index += 1
            } else if let fence = Fence(line) {
                takeCode(fence)
            } else if let heading = heading(line) {
                blocks.append(heading)
                index += 1
            } else if isRule(line) {
                blocks.append(.rule)
                index += 1
            } else if depth < Self.deepest, line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                takeQuote()
            } else if let table = takeTable() {
                blocks.append(.table(table))
            } else if Bullet(line) != nil {
                takeList()
            } else {
                takeParagraph()
            }
        }
        return blocks
    }

    // Blocks

    private mutating func takeCode(_ fence: Fence) {
        index += 1
        var body: [String] = []
        while index < lines.count, !fence.closes(lines[index]) {
            body.append(fence.undent(lines[index]))
            index += 1
        }
        if index < lines.count { index += 1 }
        blocks.append(.code(language: fence.language, text: body.joined(separator: "\n")))
    }

    private mutating func takeQuote() {
        var body: [String] = []
        while index < lines.count {
            // Only the indent comes off. Trimming the whole line would take the
            // two spaces asking for a break with it, and the quote would join
            // what a paragraph spelt the same way keeps apart.
            let marked = lines[index].drop { $0 == " " || $0 == "\t" }
            guard marked.hasPrefix(">") else { break }
            var content = String(marked.dropFirst())
            if content.hasPrefix(" ") { content.removeFirst() }
            body.append(content)
            index += 1
        }
        blocks.append(.quote(Markdown.blocks(in: body.joined(separator: "\n"), depth: depth + 1)))
    }

    private mutating func takeTable() -> MarkdownTable? {
        guard let alignments = tableAlignments(at: index) else { return nil }
        let header = Self.cells(lines[index])
        index += 2

        var rows: [[String]] = []
        while index < lines.count, !blank(lines[index]), lines[index].contains("|") {
            rows.append(Self.fitted(Self.cells(lines[index]), to: header.count))
            index += 1
        }
        return MarkdownTable(header: header, alignments: alignments, rows: rows)
    }

    /// Items are collected as the lines they were written on and flowed at the
    /// end: a wrapped item asks to be kept whole the same way a paragraph does,
    /// and folding each line in as it arrives loses the trailing spaces that say
    /// so.
    private mutating func takeList() {
        var items: [(level: Int, marker: String?, column: Int, lines: [String])] = []
        var indents: [Int] = []
        var columns: [Int] = []

        /// The deepest open item a line at this width lines up with.
        func holder(_ width: Int) -> Int? {
            columns.lastIndex { $0 <= width }
        }

        func flush() {
            guard !items.isEmpty else { return }
            blocks.append(.list(items.map {
                MarkdownListItem(level: $0.level, marker: $0.marker, text: Self.flowed($0.lines))
            }))
            items = []
        }

        while index < lines.count {
            let line = lines[index]

            if blank(line) {
                guard let next = lines[(index + 1)...].firstIndex(where: { !blank($0) }) else { break }
                if Bullet(lines[next]) != nil {
                    index = next
                    continue
                }
                guard depth < Self.deepest, let level = holder(Self.leadingWidth(lines[next])) else { break }
                index = next
                flush()
                takeInner(depth: level + 1, column: columns[level], above: indents[level])
                continue
            }

            if let bullet = Bullet(line) {
                while let deepest = indents.last, bullet.indent < deepest {
                    indents.removeLast()
                    columns.removeLast()
                }
                if indents.last.map({ bullet.indent > $0 }) ?? true {
                    indents.append(bullet.indent)
                    columns.append(bullet.column)
                }
                columns[columns.count - 1] = bullet.column
                items.append(
                    (level: max(0, indents.count - 1), marker: bullet.marker, column: bullet.column, lines: [bullet.text])
                )
                index += 1
                continue
            }

            if Fence(line) != nil || line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                guard depth < Self.deepest, let level = holder(Self.leadingWidth(line)) else { break }
                flush()
                takeInner(depth: level + 1, column: columns[level], above: indents[level])
                continue
            }
            guard !items.isEmpty, Self.leadingWidth(line) > (indents.last ?? 0) else { break }
            items[items.count - 1].lines.append(line)
            index += 1
        }
        flush()
    }

    /// What an item holds past its own lines, read as blocks of their own: a
    /// block starts level with the item's text, a wrapped line only has to be
    /// indented past the bullet, and a bullet outside a fence ends it.
    private mutating func takeInner(depth: Int, column: Int, above bulletIndent: Int) {
        let undent = column
        var body: [String] = []
        var fence: Fence?
        while index < lines.count {
            let line = lines[index]
            if let open = fence {
                if open.closes(line) { fence = nil }
            } else if blank(line) {
                guard let next = lines[(index + 1)...].firstIndex(where: { !blank($0) }),
                      Self.leadingWidth(lines[next]) >= column, Bullet(lines[next]) == nil
                else { break }
            } else if Bullet(line) != nil || Self.leadingWidth(line) <= bulletIndent {
                break
            } else if let opened = Fence(line) {
                fence = opened
            }
            body.append(Self.dropped(undent, from: line))
            index += 1
        }
        for block in Markdown.blocks(in: body.joined(separator: "\n"), depth: self.depth + 1) {
            blocks.append(.nested(depth: depth, block))
        }
    }

    private mutating func takeParagraph() {
        var body: [String] = []
        while index < lines.count, !blank(lines[index]) {
            if !body.isEmpty, startsBlock(at: index) { break }
            body.append(lines[index])
            index += 1
        }
        blocks.append(.paragraph(Self.flowed(body)))
    }

    // Recognisers

    private func blank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func startsBlock(at index: Int) -> Bool {
        let line = lines[index]
        return Fence(line) != nil
            || heading(line) != nil
            || isRule(line)
            || Bullet(line) != nil
            || line.trimmingCharacters(in: .whitespaces).hasPrefix(">")
            || tableAlignments(at: index) != nil
    }

    private func heading(_ line: String) -> MarkdownBlock? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.first == " " else { return nil }

        var text = rest.trimmingCharacters(in: .whitespaces)
        while text.hasSuffix("#") { text.removeLast() }
        return .heading(level: hashes, text: text.trimmingCharacters(in: .whitespaces))
    }

    private func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        guard let first = marks.first, "-*_".contains(first) else { return false }
        return marks.count >= 3 && marks.allSatisfy { $0 == first }
    }

    /// A table announces itself on its *second* line, so this looks ahead rather
    /// than judging the header row — which is just a line with pipes in it.
    private func tableAlignments(at index: Int) -> [MarkdownAlignment]? {
        guard index + 1 < lines.count, lines[index].contains("|") else { return nil }
        let divider = lines[index + 1]
        guard divider.contains("|"), divider.contains("-") else { return nil }

        let parts = Self.cells(divider)
        guard !parts.isEmpty, parts.count == Self.cells(lines[index]).count else { return nil }

        var alignments: [MarkdownAlignment] = []
        for part in parts {
            let dashes = part.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (part.hasPrefix(":"), part.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    // Text

    /// One block's lines run back together. A single newline is a space rather
    /// than a break: whoever wrote it wrapped to a width, and it is not the one
    /// this is being read at. Two trailing spaces or a trailing backslash are how
    /// markdown asks for a break to be kept anyway, and a blank line — which only
    /// reaches here from inside a quote — is a paragraph of its own.
    static func flowed(_ lines: [String]) -> String {
        var text = ""
        var separator = ""

        for line in lines {
            let kept = keepsTheBreak(line)
            var content = line.trimmingCharacters(in: .whitespaces)
            if content.hasSuffix("\\") { content.removeLast() }

            if content.isEmpty {
                if !text.isEmpty { separator = "\n" }
                continue
            }
            text += separator + content
            separator = kept ? "\n" : " "
        }
        return text
    }

    private static func keepsTheBreak(_ line: String) -> Bool {
        line.hasSuffix("  ") || line.trimmingCharacters(in: .whitespaces).hasSuffix("\\")
    }

    private static func cells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") { trimmed.removeLast() }
        return trimmed.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func fitted(_ row: [String], to width: Int) -> [String] {
        if row.count == width { return row }
        if row.count > width { return Array(row.prefix(width)) }
        return row + Array(repeating: "", count: width - row.count)
    }

    private static func dropped(_ width: Int, from line: String) -> String {
        var dropped = 0
        var rest = Substring(line)
        while dropped < width, let character = rest.first, character == " " || character == "\t" {
            dropped += character == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }

    private static func leadingWidth(_ line: String) -> Int {
        var width = 0
        for character in line {
            if character == " " { width += 1 } else if character == "\t" { width += 4 } else { break }
        }
        return width
    }
}

private struct Fence {
    let character: Character
    let length: Int
    let indent: Int
    let language: String?

    init?(_ line: String) {
        var indent = 0
        var rest = Substring(line)
        while let character = rest.first, character == " " || character == "\t" {
            indent += character == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }

        guard let opener = rest.first, opener == "`" || opener == "~" else { return nil }
        let run = rest.prefix { $0 == opener }.count
        guard run >= 3 else { return nil }

        let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        // Inline code that happens to start a line: "```x``` and more".
        if opener == "`", info.contains("`") { return nil }
        self.character = opener
        self.length = run
        self.indent = indent
        self.language = info.isEmpty ? nil : info
    }

    func closes(_ line: String) -> Bool {
        let rest = line.drop { $0 == " " || $0 == "\t" }
        guard rest.prefix(while: { $0 == character }).count >= length else { return false }
        return rest.allSatisfy { $0 == character || $0 == " " }
    }

    func undent(_ line: String) -> String {
        var dropped = 0
        var rest = Substring(line)
        while dropped < indent, let character = rest.first, character == " " || character == "\t" {
            dropped += character == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }
        return String(rest)
    }
}

private struct Bullet {
    let indent: Int
    let marker: String?
    let text: String
    /// Where the item's text starts, which is where anything it holds lines up.
    /// Past four spaces the text is code and the column is one past the marker.
    let column: Int

    init?(_ line: String) {
        var indent = 0
        var rest = Substring(line)
        while let character = rest.first, character == " " || character == "\t" {
            indent += character == "\t" ? 4 : 1
            rest = rest.dropFirst()
        }

        if let opener = rest.first, "-*+".contains(opener), rest.dropFirst().first == " " {
            self.indent = indent
            self.marker = nil
            self.text = String(rest.dropFirst().drop { $0 == " " })
            self.column = Self.column(indent + 1, rest.dropFirst())
            return
        }

        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let punctuation = after.first, punctuation == "." || punctuation == ")",
              after.dropFirst().first == " "
        else { return nil }

        self.indent = indent
        self.marker = "\(digits)."
        self.text = String(after.dropFirst().drop { $0 == " " })
        self.column = Self.column(indent + digits.count + 1, after.dropFirst())
    }

    private static func column(_ marker: Int, _ rest: Substring) -> Int {
        let spaces = rest.prefix { $0 == " " }.count
        return marker + (spaces > 4 || spaces == rest.count ? 1 : spaces)
    }
}
