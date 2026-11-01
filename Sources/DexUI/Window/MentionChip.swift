import DexCore
import AppKit
import SwiftUI

extension MentionSource {
    var tint: NSColor {
        switch self {
        case .dexSession: .controlAccentColor
        case .linearIssue: NSColor(red: 0.37, green: 0.42, blue: 0.82, alpha: 1)
        case .notionPage: .secondaryLabelColor
        case .slack: NSColor(red: 0.88, green: 0.12, blue: 0.35, alpha: 1)
        case .github: .labelColor
        }
    }

    /// The app's own icon where it is installed, else the source's symbol in its tint.
    @MainActor
    var icon: NSImage {
        if let cached = MentionIcons.cache[self] { return cached }
        let icon = MentionIcons.appIcon(for: self) ?? MentionIcons.symbol(for: self)
        MentionIcons.cache[self] = icon
        return icon
    }
}

@MainActor
enum MentionIcons {
    static var cache: [MentionSource: NSImage] = [:]

    static func appIcon(for source: MentionSource) -> NSImage? {
        // Sessions are this app's own.
        if source == .dexSession, let own = Bundle.main.bundleIdentifier,
           source.bundleIdentifiers.contains(own) {
            return NSApp.applicationIconImage
        }
        for id in source.bundleIdentifiers {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                return NSWorkspace.shared.icon(forFile: app.path)
            }
        }
        return nil
    }

    static func symbol(for source: MentionSource) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [source.tint]))
        let image = NSImage(systemSymbolName: source.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        return image ?? NSImage()
    }
}

/// The icon a menu row leads with, so it is clear where a result comes from.
struct MentionSourceIcon: View {
    let source: MentionSource

    var body: some View {
        Image(nsImage: source.icon)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: ChromeMetrics.mentionIcon, height: ChromeMetrics.mentionIcon)
    }
}

/// A mention in the field: one character, so it deletes as a unit and there is
/// nothing inside it to put the caret in. Keeps the token it was read from, so
/// writing the draft back out gives the same string.
final class MentionChipAttachment: NSTextAttachment {
    let mention: Mention
    let token: String

    @MainActor
    init(mention: Mention, token: String? = nil, font: NSFont) {
        self.mention = mention
        self.token = token ?? ComposerChips.token(for: mention)
        super.init(data: nil, ofType: nil)
        let chip = MentionChipImage(mention: mention, font: font)
        image = chip.image
        bounds = chip.bounds
    }

    required init?(coder: NSCoder) {
        fatalError("MentionChipAttachment is never archived")
    }
}

/// Drawn at draw time rather than once, so the chip follows light and dark.
@MainActor
struct MentionChipImage {
    let image: NSImage
    let bounds: CGRect

    static let padding: CGFloat = 5
    static let gap: CGFloat = 3
    static let longestTitle: CGFloat = 260

    init(mention: Mention, font: NSFont) {
        let height = ceil(font.ascender - font.descender)
        let titleFont = NSFont.systemFont(ofSize: font.pointSize - 1, weight: .medium)
        let iconSide = floor(height - 4)
        let title = mention.title as NSString
        let titleWidth = min(ceil(title.size(withAttributes: [.font: titleFont]).width), Self.longestTitle)
        let width = Self.padding + iconSide + Self.gap + titleWidth + Self.padding + 1
        let size = NSSize(width: width, height: height)
        let icon = mention.source.icon
        let tint = mention.source.tint
        let padding = Self.padding
        let isPending = mention.isPending
        let isClosed = mention.isClosed
        // The chip's bottom sits at the line's descender, so this is the line's baseline.
        let baseline = -font.descender
        let gap = Self.gap

        let image = NSImage(size: size, flipped: false) { rect in
            let box = NSBezierPath(roundedRect: rect.insetBy(dx: 0.25, dy: 0.25), xRadius: 4, yRadius: 4)
            tint.withAlphaComponent(0.15).setFill()
            box.fill()
            tint.withAlphaComponent(0.25).setStroke()
            box.lineWidth = 0.5
            box.stroke()

            icon.draw(in: NSRect(x: padding, y: (rect.height - iconSide) / 2,
                                 width: iconSide, height: iconSide))

            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            var attributes: [NSAttributedString.Key: Any] = [
                .font: titleFont,
                .foregroundColor: isPending ? NSColor.secondaryLabelColor : NSColor.labelColor,
                .paragraphStyle: style,
            ]
            if isClosed { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            let lineHeight = titleFont.ascender - titleFont.descender
            title.draw(
                with: NSRect(x: padding + iconSide + gap,
                             y: baseline + titleFont.descender,
                             width: titleWidth, height: lineHeight),
                options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin],
                attributes: attributes
            )
            return true
        }
        image.cacheMode = .never
        self.image = image
        self.bounds = CGRect(x: 0, y: font.descender, width: width, height: height)
    }
}

/// The draft string and the field's text, each read off the other.
@MainActor
enum ChipText {
    static let pasteboardType = NSPasteboard.PasteboardType(BundleIdentity.prefix + ".dex.composer-draft")

    static func attributed(_ draft: String, attributes: [NSAttributedString.Key: Any]) -> NSAttributedString {
        let font = attributes[.font] as? NSFont ?? ChromeType.Reading.editorFont
        let built = NSMutableAttributedString()
        for piece in ComposerChips.pieces(of: draft) {
            switch piece {
            case .text(let text):
                built.append(NSAttributedString(string: text, attributes: attributes))
            case .chip(let mention):
                built.append(chip(mention, attributes: attributes, font: font))
            }
        }
        return built
    }

    static func chip(_ mention: Mention, attributes: [NSAttributedString.Key: Any], font: NSFont) -> NSAttributedString {
        let chip = NSMutableAttributedString(attachment: MentionChipAttachment(mention: mention, font: font))
        chip.addAttributes(attributes, range: NSRange(location: 0, length: chip.length))
        return chip
    }

    static func draft(from text: NSAttributedString, in range: NSRange? = nil) -> String {
        let range = range ?? NSRange(location: 0, length: text.length)
        let string = text.string as NSString
        var draft = ""
        text.enumerateAttribute(.attachment, in: range) { value, run, _ in
            guard let chip = value as? MentionChipAttachment else {
                draft += string.substring(with: run)
                    .replacingOccurrences(of: ComposerChips.placeholder, with: "")
                return
            }
            draft += String(repeating: chip.token, count: run.length)
        }
        return draft
    }

    /// Whether the character at each end is the same text, or the same chip.
    static func sameUnit(_ left: NSAttributedString, _ at: Int, _ right: NSAttributedString, _ other: Int) -> Bool {
        let a = (left.string as NSString).character(at: at)
        let b = (right.string as NSString).character(at: other)
        guard a == b else { return false }
        let chipA = left.attribute(.attachment, at: at, effectiveRange: nil) as? MentionChipAttachment
        let chipB = right.attribute(.attachment, at: other, effectiveRange: nil) as? MentionChipAttachment
        return chipA?.token == chipB?.token
    }
}
