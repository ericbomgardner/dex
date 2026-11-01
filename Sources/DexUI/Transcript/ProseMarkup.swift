import DexCore
import AppKit
import SwiftUI

/// What a run of prose is set in. Named rather than passed as a font so the
/// markup can derive bold, italic and code from it.
struct ProseFace: Hashable, Sendable {
    var size: CGFloat = ChromeType.Reading.bodySize
    var weight: NSFont.Weight = .regular
    var italic = false
    var mono = false
    var tint: ProseTint = .primary

    /// A slab of code is read down as much as across, so it is set tighter than
    /// the prose around it.
    var lead: CGFloat = ChromeMetrics.readingLead

    /// How many quotes the run sits inside, for a copy to mark it with `> `.
    var quoted = 0

    static let code = ProseFace(
        size: ChromeType.Reading.monoSize,
        mono: true,
        tint: .secondary,
        lead: ChromeMetrics.monoLead
    )
}

package enum ProseTint: Hashable, Sendable {
    case primary
    case secondary
    case tertiary
    /// A result that came back an error, which the pane has always drawn in the
    /// same orange as the glyph on its row.
    case warning
}

/// Either a reply's parsed markdown or a stretch of text that was never markdown
/// at all — what you typed, which the pane has always drawn as the characters
/// you sent rather than as markup.
enum ProseSource: Hashable, Sendable {
    case markdown([MarkdownBlock])
    case plain(String)
}

/// Prose as an attributed string, laid out to the same rhythm the SwiftUI stack
/// was: the gap between blocks becomes paragraph spacing, a bullet's slot
/// becomes a pair of tab stops, and the leading the pane reads in becomes line
/// spacing.
///
/// It is one string rather than a view apiece because a selection can only run
/// through characters that share a layout — paragraph to paragraph inside a
/// reply is a text-view selection, and everything past that is the pane's.
extension NSAttributedString.Key {
    /// A heading's level, set on its text so a copy can tell it from a
    /// semibold table header without reading the font.
    static let proseHeading = NSAttributedString.Key("DexProseHeading")
}

package enum ProseMarkup {

    static func attributed(_ source: ProseSource, face: ProseFace) -> NSAttributedString {
        switch source {
        case .plain(let text):
            return NSAttributedString(string: text, attributes: [
                .font: font(face),
                .foregroundColor: color(face.tint),
                .paragraphStyle: style(lead: face.lead),
            ])

        case .markdown(let blocks):
            let result = NSMutableAttributedString()
            for (index, block) in blocks.enumerated() {
                append(block, at: index, face: face, to: result)
            }
            trimTrailingBreak(result)
            return result
        }
    }

    /// Only the kinds that read as running text. A slab of code or a table is
    /// drawn as itself and crossed whole, which is what `selectableWhole` is for.
    static func flows(_ block: MarkdownBlock) -> Bool {
        switch block {
        case .heading, .paragraph, .list: true
        case .code, .quote, .table, .rule: false
        case .nested(_, let inner): flows(inner)
        }
    }

    /// Where a block inside a list item starts: level with the item's text.
    static func inset(_ depth: Int) -> CGFloat {
        guard depth > 0 else { return 0 }
        return CGFloat(depth - 1) * ChromeMetrics.listIndent + ChromeMetrics.bulletSlot + ChromeMetrics.iconGap
    }

    /// Tabs are how the bullet finds its column, and nobody wants them on the
    /// clipboard.
    package static func plain(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n\t", with: "\n")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " "))
    }

    // MARK: - Blocks

    private static func append(
        _ block: MarkdownBlock,
        at index: Int,
        face: ProseFace,
        to result: NSMutableAttributedString,
        inset: CGFloat = 0
    ) {
        switch block {
        case .heading(let level, let text):
            // A heading belongs to what follows it, so the extra space goes above
            // rather than evenly between the paragraphs either side.
            let style = style(before: index > 0 ? ChromeMetrics.headingLead : 0,
                              after: gap(ChromeMetrics.blockGap))
            style.firstLineHeadIndent = inset
            style.headIndent = inset
            let start = result.length
            result.append(inline(text, font: heading(level), tint: face.tint, style: style))
            result.addAttribute(.proseHeading, value: level, range: NSRange(location: start, length: result.length - start))
            result.append(paragraphBreak(style))

        case .paragraph(let text):
            let style = style(after: gap(ChromeMetrics.blockGap))
            style.firstLineHeadIndent = inset
            style.headIndent = inset
            result.append(inline(text, font: font(face), tint: face.tint, style: style))
            result.append(paragraphBreak(style))

        case .list(let items):
            for (position, item) in items.enumerated() {
                let last = position == items.count - 1
                let indent = inset + CGFloat(item.level) * ChromeMetrics.listIndent
                let style = style(after: gap(last ? ChromeMetrics.blockGap : ChromeMetrics.listGap))
                style.firstLineHeadIndent = indent
                style.headIndent = indent + ChromeMetrics.bulletSlot + ChromeMetrics.iconGap
                style.tabStops = [
                    NSTextTab(textAlignment: .right, location: indent + ChromeMetrics.bulletSlot),
                    NSTextTab(textAlignment: .left,
                              location: indent + ChromeMetrics.bulletSlot + ChromeMetrics.iconGap),
                ]

                result.append(NSAttributedString(
                    string: "\t\(item.marker ?? "•")\t",
                    attributes: [
                        .font: font(face),
                        .foregroundColor: color(.tertiary),
                        .paragraphStyle: style,
                    ]
                ))
                result.append(inline(item.text, font: font(face), tint: face.tint, style: style))
                result.append(paragraphBreak(style))
            }

        case .nested(let depth, let inner):
            append(inner, at: index, face: face, to: result, inset: inset + Self.inset(depth))

        case .code, .quote, .table, .rule:
            break
        }
    }

    /// The break carries the paragraph it ends, since that is where the spacing
    /// under a paragraph is measured from. The last one is cut: TextKit reads a
    /// trailing newline as an empty paragraph and gives it a line of its own.
    private static func paragraphBreak(_ style: NSParagraphStyle) -> NSAttributedString {
        NSAttributedString(string: "\n", attributes: [.paragraphStyle: style])
    }

    private static func trimTrailingBreak(_ result: NSMutableAttributedString) {
        guard result.string.hasSuffix("\n") else { return }
        result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
    }

    // MARK: - Inline markup

    private static func inline(
        _ text: String,
        font base: NSFont,
        tint: ProseTint,
        style: NSParagraphStyle
    ) -> NSAttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let parsed = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)

        let result = NSMutableAttributedString()
        for run in parsed.runs {
            let intent = run.inlinePresentationIntent
            var font = base
            if intent?.contains(.stronglyEmphasized) == true { font = traits(font, .bold) }
            if intent?.contains(.emphasized) == true { font = traits(font, .italic) }
            if intent?.contains(.code) == true {
                font = NSFont.monospacedSystemFont(ofSize: base.pointSize, weight: .regular)
            }

            var attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: color(tint),
                .paragraphStyle: style,
            ]
            if intent?.contains(.strikethrough) == true {
                attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if let link = run.link {
                attributes[.link] = link
                attributes[.foregroundColor] = NSColor.linkColor
                attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }

            result.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
        }
        return result
    }

    // MARK: - Faces

    private static func font(_ face: ProseFace) -> NSFont {
        let base = face.mono
            ? NSFont.monospacedSystemFont(ofSize: face.size, weight: face.weight)
            : NSFont.systemFont(ofSize: face.size, weight: face.weight)
        return face.italic ? traits(base, .italic) : base
    }

    private static func heading(_ level: Int) -> NSFont {
        switch level {
        case 1: NSFont.systemFont(ofSize: 18, weight: .semibold)
        case 2: NSFont.systemFont(ofSize: 16, weight: .semibold)
        // Set level with the prose it heads and told apart by weight alone, so
        // it moves with the reading size rather than being written down here.
        default: NSFont.systemFont(ofSize: ChromeType.Reading.bodySize, weight: .semibold)
        }
    }

    private static func traits(_ font: NSFont, _ added: NSFontDescriptor.SymbolicTraits) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(added))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    private static func color(_ tint: ProseTint) -> NSColor {
        switch tint {
        case .primary: .labelColor
        case .secondary: .secondaryLabelColor
        case .tertiary: .tertiaryLabelColor
        case .warning: .systemOrange
        }
    }

    private static func style(
        before: CGFloat = 0,
        after: CGFloat = 0,
        lead: CGFloat = ChromeMetrics.readingLead
    ) -> NSMutableParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lead
        style.paragraphSpacingBefore = before
        style.paragraphSpacing = after
        return style
    }

    /// A gap the stack used to hold open between two views, as the spacing
    /// between two paragraphs of one. TextKit puts the reading leading between
    /// them first, so what is left to add is the rest of it.
    private static func gap(_ design: CGFloat) -> CGFloat {
        max(0, design - ChromeMetrics.readingLead)
    }
}
