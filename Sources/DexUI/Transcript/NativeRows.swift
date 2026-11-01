import DexCore
import AppKit
import SwiftUI

/// The rows most of a transcript is made of, drawn in AppKit rather than
/// SwiftUI: replies that are all running text, prompts, what a summary said,
/// Thoughts, and tool runs and calls while they are shut. Together they are
/// about nine rows in ten. A cell for one of these is a handful of views
/// refilled in place, and its height is worked out from the text alone, on any
/// thread — so a transcript can be measured as it is read rather than as it is
/// drawn. Everything else stays the SwiftUI view it was.
///
/// Each kind is laid out to match its SwiftUI view to the point; the native
/// parity probe draws both for every such row in real transcripts and fails on
/// any difference in height.
package enum NativeRow: Hashable, Sendable {
    /// A reply with nothing in it but paragraphs, headings and lists.
    case reply([MarkdownBlock])
    /// The assistant speaking through a block the server summarised.
    case narration([MarkdownBlock])
    case prompt(String, waiting: Bool)
    case thinking(key: String, text: String, expanded: Bool)
    /// Several calls folded into one line, shut.
    case run(key: String, count: Int, sentence: String, pending: Bool)
    /// One call, shut, with no agent behind it and nothing still running.
    case call(key: String, glyph: String, tint: CallTint, name: String, summary: String?, note: String?)

    package enum CallTint: Hashable, Sendable {
        case accent, failed, quiet
    }

    /// The fold a press on the row turns, where it has one.
    var fold: String? {
        switch self {
        case .thinking(let key, _, _), .run(let key, _, _, _), .call(let key, _, _, _, _, _): key
        default: nil
        }
    }

    /// What a drag through the row takes when it takes the row whole.
    var wholeText: String? {
        switch self {
        case .run(_, let count, let sentence, _): "\(sentence) · \(count) calls"
        case .call(_, _, _, let name, let summary, _): [name, summary].compactMap { $0 }.joined(separator: " ")
        default: nil
        }
    }

    // MARK: - Reading a transcript item

    /// The native form of an item, or nil for one only its SwiftUI view draws.
    @MainActor
    package static func of(_ item: TranscriptItem, isLive: Bool) -> NativeRow? {
        let expansions = RowExpansions.shared
        switch item {
        case .reply(let reply) where reply.blocks.allSatisfy(ProseMarkup.flows):
            return .reply(reply.blocks)
        case .narration(let reply):
            return .narration(reply.blocks)
        case .prompt(let prose):
            return .prompt(prose.text, waiting: false)
        case .thinking(let prose):
            let key = "think:\(prose.id)"
            return .thinking(key: key, text: prose.text, expanded: expansions.isExpanded(key))
        case .toolRun(let run):
            if let only = run.calls.first, run.isSingle {
                return call(only)
            }
            let key = "run:\(run.id)"
            guard !expansions.isExpanded(key) else { return nil }
            return .run(key: key, count: run.calls.count, sentence: run.sentence, pending: run.isPending)
        default:
            return nil
        }
    }

    /// A call row the way `ToolCallRow` draws one that is shut, not running,
    /// and not an agent — an agent's row reads its model off disk and opens
    /// onto a conversation, which is SwiftUI's to do.
    @MainActor
    private static func call(_ call: ToolCall) -> NativeRow? {
        let key = "call:\(call.id)"
        guard !call.isDelegation, !RowExpansions.shared.isExpanded(key) else { return nil }
        let tint: CallTint = call.isPending || call.neverCameBack
            ? .quiet
            : call.result?.isError == true || call.wasDropped ? .failed : .accent
        let note = call.neverCameBack || call.isPending
            ? "never came back"
            : call.wasDropped ? ToolCall.droppedNote : nil
        return .call(
            key: key, glyph: ToolGlyph.name(for: call.name), tint: tint,
            name: call.heading(running: false), summary: call.subheading, note: note
        )
    }

    // MARK: - Measuring

    /// The row's height below its lead, at a text column this wide. Safe off
    /// the main thread: it asks TextKit and the fonts, nothing else.
    package nonisolated func height(width: CGFloat, metrics: NativeMetrics) -> CGFloat {
        switch self {
        case .reply(let blocks):
            return ProseView.size(of: .markdown(blocks), face: ProseFace(), width: width).height
        case .narration(let blocks):
            return metrics.labelLine + ChromeMetrics.iconGap
                + ProseView.size(of: .markdown(blocks), face: ProseFace(), width: width).height
        case .prompt(let text, _):
            return Self.bubble(text, width: width).height + 2 * ChromeMetrics.cardVertical
        case .thinking(_, let text, let expanded):
            guard expanded else { return metrics.thoughtLine }
            return metrics.thoughtLine + ChromeMetrics.iconGap
                + ProseView.size(of: .plain(text), face: Self.thoughtFace, width: width - ChromeMetrics.glyphGap).height
        case .run:
            return metrics.header(glyph: "chevron.right").height
        case .call(_, let glyph, _, _, _, _):
            return metrics.header(glyph: glyph).height
        }
    }

    /// What follows a run's sentence: how many calls, and whether one was lost.
    nonisolated static func tally(count: Int, pending: Bool) -> String {
        // A run is only ever flushed flat by something said after it, so a call
        // still pending in one was abandoned, never running.
        pending ? "\(count) calls · never came back" : "\(count) calls"
    }

    nonisolated static let promptFace = ProseFace(weight: .medium)
    nonisolated static let thoughtFace = ProseFace(size: 13, italic: true, tint: .secondary)

    /// The text of a prompt hugs its own longest line, inside the card.
    nonisolated static func bubble(_ text: String, width: CGFloat) -> CGSize {
        let offered = max(1, width - ChromeMetrics.promptIndent - 2 * ChromeMetrics.cardHorizontal)
        let used = ProseView.size(of: .plain(text), face: promptFace, width: offered)
        return CGSize(width: min(used.width, offered), height: used.height)
    }
}

/// The single lines the native rows set, measured off the faces SwiftUI sets
/// them in. Worked out once on the main thread and handed to measuring
/// wherever it runs.
package struct NativeMetrics: Sendable {
    /// "Thought" with its chevron.
    let thoughtLine: CGFloat
    /// "summarized" over a narration.
    let labelLine: CGFloat

    /// How far a glyph reaches above and below the baseline it sits on, which
    /// a symbol carries in its alignment rect. A few reach further than the
    /// text beside them and make their line a point taller, in SwiftUI too.
    struct Glyph: Sendable {
        let above: CGFloat
        let below: CGFloat
    }

    let glyphs: [String: Glyph]

    /// A tool line's height and where its baseline falls, for the glyph it
    /// leads with: the deepest reach above and below among the faces and the
    /// glyph, the way a stack lined up on its first baseline comes out.
    func header(glyph: String) -> (height: CGFloat, baseline: CGFloat) {
        let text = Self.metaMedium
        let mark = glyphs[glyph] ?? Glyph(above: 0, below: 0)
        let above = max(text.ascender, mark.above)
        let below = max(-text.descender, mark.below)
        return (ceil(above + below), (above * 2).rounded() / 2)
    }

    package nonisolated(unsafe) static let meta = NSFont.systemFont(ofSize: 13)
    package nonisolated(unsafe) static let metaMedium = NSFont.systemFont(ofSize: 13, weight: .medium)
    package nonisolated(unsafe) static let metaItalic = italic(meta)
    package nonisolated(unsafe) static let mono = NSFont.monospacedSystemFont(ofSize: ChromeType.Reading.monoSize, weight: .regular)
    static let iconPoint: CGFloat = 12

    static func italic(_ font: NSFont) -> NSFont {
        let descriptor = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.italic))
        return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
    }

    /// How tall SwiftUI sets one line of a face: its line box, to the point.
    nonisolated static func line(_ font: NSFont) -> CGFloat {
        ceil(font.ascender - font.descender + font.leading)
    }

    @MainActor package static let current: NativeMetrics = {
        let symbol = NativeGlyph.image("chevron.right", color: .labelColor)?.size.height ?? 0
        var glyphs: [String: Glyph] = [:]
        for name in ToolGlyph.all + ["chevron.right", "chevron.down"] {
            guard let image = NativeGlyph.image(name, color: .labelColor) else { continue }
            glyphs[name] = Glyph(
                above: image.size.height - image.alignmentRect.minY,
                below: image.alignmentRect.minY
            )
        }
        return NativeMetrics(
            thoughtLine: max(line(metaItalic), symbol),
            labelLine: line(metaItalic),
            glyphs: glyphs
        )
    }()
}

/// An SF Symbol at the transcript's icon size, in a colour.
package enum NativeGlyph {
    @MainActor private static var made: [String: NSImage] = [:]

    /// Resolved in the appearance it is drawn in, so a switch to dark or back
    /// doesn't leave a glyph in the other's colour.
    @MainActor package static func image(_ name: String, color: NSColor) -> NSImage? {
        let appearance = NSAppearance.currentDrawing()
        let key = "\(name)#\(color.description)#\(appearance.name.rawValue)"
        if let image = made[key] { return image }
        var resolved = color
        appearance.performAsCurrentDrawingAppearance {
            resolved = color.usingColorSpace(.sRGB) ?? color
        }
        let configuration = NSImage.SymbolConfiguration(pointSize: NativeMetrics.iconPoint, weight: .regular, scale: .medium)
            .applying(.init(paletteColors: [resolved]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        made[key] = image
        return image
    }
}

/// One native row, refilled in place as the column moves it.
@MainActor
package final class NativeCell: NSView {

    private(set) var row: NativeRow?
    private var lead: CGFloat = 0
    private var place = 0
    private var onFold: ((String) -> Void)?
    private struct Look: Equatable {
        let scheme: ColorScheme
        let selection: ObjectIdentifier?
    }
    private var shown: Look?
    /// A prompt's text, measured once per prompt and width.
    private var bubbleSize: (width: CGFloat, size: CGSize)?

    private let prose = ProseView()
    private let bubble = NativeBubble()
    private let header = NativeHeader()
    private let label = NativeHeader()
    private let whole = WholeSelectionView()

    package override var isFlipped: Bool { true }

    /// The space around the row's pieces is the column's margin, where a press
    /// starts a selection — not the row's.
    package override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    package override init(frame: NSRect) {
        super.init(frame: frame)
        addSubview(bubble)
        addSubview(prose)
        addSubview(header)
        addSubview(label)
        header.addSubview(whole)
        header.press = { [weak self] in
            guard let fold = self?.row?.fold else { return }
            self?.onFold?(fold)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    package func show(
        _ row: NativeRow, lead: CGFloat, place: Int,
        environment: EnvironmentValues, onFold: @escaping (String) -> Void
    ) {
        let scheme = environment.colorScheme
        let selection = environment.transcriptSelection
        let now = Look(
            scheme: scheme, selection: selection.map(ObjectIdentifier.init)
        )
        self.onFold = onFold
        // Asked again on every redraw of the pane; a row already showing is
        // left as it is.
        if row == self.row, lead == self.lead, place == self.place, shown == now {
            return
        }
        if row != self.row { bubbleSize = nil }
        self.row = row
        self.lead = lead
        self.place = place
        shown = now

        follow(scheme)

        prose.isHidden = true
        bubble.isHidden = true
        header.isHidden = true
        label.isHidden = true
        whole.attach(to: nil, at: [])

        switch row {
        case .reply(let blocks):
            prose.isHidden = false
            prose.show(.markdown(blocks), face: ProseFace())
        case .narration(let blocks):
            label.isHidden = false
            label.content = .label("summarized")
            prose.isHidden = false
            prose.show(.markdown(blocks), face: ProseFace())
        case .prompt(let text, let waiting):
            bubble.isHidden = false
            bubble.alphaValue = waiting ? ChromeMetrics.waitingPrompt : 1
            bubble.fill = NSColor(Entry.flavor.accentTint).withAlphaComponent(ChromeMetrics.promptTint)
            prose.isHidden = false
            prose.alphaValue = waiting ? ChromeMetrics.waitingPrompt : 1
            prose.show(.plain(text), face: NativeRow.promptFace)
        case .thinking(_, let text, let expanded):
            header.isHidden = false
            header.content = .thought(expanded: expanded)
            if expanded {
                prose.isHidden = false
                prose.show(.plain(text), face: NativeRow.thoughtFace)
            }
        case .run(_, let count, let sentence, let pending):
            header.isHidden = false
            header.content = .run(count: count, sentence: sentence, pending: pending)
        case .call(_, let glyph, let tint, let name, let summary, let note):
            header.isHidden = false
            header.content = .call(glyph: glyph, tint: tint, name: name, summary: summary, note: note)
        }
        if prose.isHidden { prose.alphaValue = 1 }

        // The same places the SwiftUI rows give their pieces: the row's, then
        // the first piece in it.
        if !prose.isHidden { prose.attach(to: selection, at: [place, 0]) } else { prose.attach(to: nil, at: []) }
        if let text = row.wholeText {
            whole.text = text
            whole.html = nil
            whole.attach(to: selection, at: [place, 0])
        }
        header.setAccessibilityLabel(row.wholeText ?? (row.fold != nil ? "Thought" : nil))
        needsLayout = true
    }

    /// Off screen and out of the selection until it is given another row.
    func clear() {
        row = nil
        shown = nil
        prose.attach(to: nil, at: [])
        whole.attach(to: nil, at: [])
    }

    package override func layout() {
        super.layout()
        guard let row else { return }
        let width = min(ChromeMetrics.readingMeasure, bounds.width - 2 * ChromeMetrics.readingInset)
        let x = (bounds.width - width) / 2
        let metrics = NativeMetrics.current
        var y = lead

        switch row {
        case .reply:
            prose.frame = NSRect(x: x, y: y, width: width, height: bounds.height - y)
        case .narration:
            label.frame = NSRect(x: x, y: y, width: width, height: metrics.labelLine)
            y += metrics.labelLine + ChromeMetrics.iconGap
            prose.frame = NSRect(x: x, y: y, width: width, height: bounds.height - y)
        case .prompt(let text, _):
            let size = bubbleSize.flatMap { $0.width == width ? $0.size : nil } ?? NativeRow.bubble(text, width: width)
            bubbleSize = (width, size)
            let card = NSRect(
                x: x + width - size.width - 2 * ChromeMetrics.cardHorizontal, y: y,
                width: size.width + 2 * ChromeMetrics.cardHorizontal,
                height: size.height + 2 * ChromeMetrics.cardVertical
            )
            bubble.frame = card
            prose.frame = card.insetBy(dx: ChromeMetrics.cardHorizontal, dy: ChromeMetrics.cardVertical)
        case .thinking(_, _, let expanded):
            header.frame = NSRect(x: x, y: y, width: width, height: metrics.thoughtLine)
            if expanded {
                y += metrics.thoughtLine + ChromeMetrics.iconGap
                prose.frame = NSRect(
                    x: x + ChromeMetrics.glyphGap, y: y,
                    width: width - ChromeMetrics.glyphGap, height: bounds.height - y
                )
            }
        case .run:
            header.frame = NSRect(x: x, y: y, width: width, height: metrics.header(glyph: "chevron.right").height)
        case .call(_, let glyph, _, _, _, _):
            header.frame = NSRect(x: x, y: y, width: width, height: metrics.header(glyph: glyph).height)
        }
        whole.frame = header.bounds
    }
}

/// A prompt's card.
final class NativeBubble: NSView {
    var fill: NSColor = .clear { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        fill.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: ChromeMetrics.promptCorner, yRadius: ChromeMetrics.promptCorner).fill()
    }
}

/// One line of a native row: a glyph and some words, set the way the SwiftUI
/// header beside it would set them, and pressed to turn the row's fold.
@MainActor
package final class NativeHeader: NSView {

    package enum Content: Equatable {
        case none
        case label(String)
        case thought(expanded: Bool)
        case run(count: Int, sentence: String, pending: Bool)
        case call(glyph: String, tint: NativeRow.CallTint, name: String, summary: String?, note: String?)
    }

    package var content: Content = .none { didSet { if content != oldValue { needsDisplay = true } } }
    var press: (() -> Void)?
    private var pressing = false

    package override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    /// Taken on the first click, as a SwiftUI button in the same place is.
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    package override func accessibilityPerformPress() -> Bool {
        press?()
        return press != nil
    }

    package override func hitTest(_ point: NSPoint) -> NSView? {
        guard case .label = content else { return super.hitTest(point) }
        return nil
    }

    package override func mouseDown(with event: NSEvent) {
        pressing = true
        alphaValue = 0.75
    }

    package override func mouseUp(with event: NSEvent) {
        alphaValue = 1
        defer { pressing = false }
        guard pressing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press?()
    }

    package override func draw(_ dirtyRect: NSRect) {
        let tertiary = NSColor.tertiaryLabelColor
        let secondary = NSColor.secondaryLabelColor
        switch content {
        case .none:
            return
        case .label(let text):
            draw(text, font: NativeMetrics.metaItalic, color: tertiary, at: 0, width: bounds.width)
        case .thought(let expanded):
            // Centred on each other, as an HStack does with no baseline asked for.
            let glyph = NativeGlyph.image(expanded ? "chevron.down" : "chevron.right", color: tertiary)
            var x: CGFloat = 0
            if let glyph {
                glyph.draw(in: NSRect(
                    x: 0, y: (bounds.height - glyph.size.height) / 2,
                    width: glyph.size.width, height: glyph.size.height
                ))
                x = glyph.size.width + ChromeMetrics.iconGap
            }
            let line = NativeMetrics.line(NativeMetrics.metaItalic)
            draw("Thought", font: NativeMetrics.metaItalic, color: tertiary,
                 at: x, y: (bounds.height - line) / 2, width: bounds.width - x)
        case .run(let count, let sentence, let pending):
            slot("chevron.right", color: tertiary)
            let x = ChromeMetrics.toolGlyphSlot + ChromeMetrics.iconGap
            let tally = NativeRow.tally(count: count, pending: pending)
            let tallyWidth = width(tally, font: NativeMetrics.meta)
            let room = max(0, bounds.width - x - tallyWidth - ChromeMetrics.iconGap)
            draw(tally, font: NativeMetrics.meta, color: tertiary,
                 at: x + min(width(sentence, font: NativeMetrics.metaMedium), room) + ChromeMetrics.iconGap,
                 width: tallyWidth)
            draw(sentence, font: NativeMetrics.metaMedium, color: secondary, at: x, width: room, truncate: .byTruncatingMiddle)
        case .call(let glyph, let tint, let name, let summary, let note):
            let color: NSColor = switch tint {
            case .accent: NSColor(Entry.flavor.accent)
            case .failed: .systemRed
            case .quiet: secondary
            }
            slot(glyph, color: color)
            var x = ChromeMetrics.toolGlyphSlot + ChromeMetrics.iconGap
            var right = bounds.width
            if let note {
                let noteWidth = width(note, font: NativeMetrics.meta)
                right -= noteWidth
                draw(note, font: NativeMetrics.meta, color: tertiary, at: right, width: noteWidth)
                right -= ChromeMetrics.iconGap
            }
            x += draw(name, font: NativeMetrics.metaMedium, color: secondary, at: x,
                      width: max(0, right - x), truncate: .byTruncatingTail)
            if let summary {
                x += ChromeMetrics.iconGap
                draw(summary, font: NativeMetrics.mono, color: tertiary, at: x,
                     width: max(0, right - x), truncate: .byTruncatingMiddle)
            }
        }
    }

    /// The glyph in its slot, its alignment rect's foot on the line's
    /// baseline, the way `.firstTextBaseline` sits a symbol.
    private func slot(_ name: String, color: NSColor) {
        guard let image = NativeGlyph.image(name, color: color) else { return }
        image.draw(in: NSRect(
            x: 0, y: baselineY - (image.size.height - image.alignmentRect.minY),
            width: image.size.width, height: image.size.height
        ))
    }

    /// Where the line's baseline falls, from the top.
    private var baselineY: CGFloat {
        let metrics = NativeMetrics.current
        return switch content {
        case .run: metrics.header(glyph: "chevron.right").baseline
        case .call(let glyph, _, _, _, _): metrics.header(glyph: glyph).baseline
        default: (NativeMetrics.meta.ascender * 2).rounded() / 2
        }
    }

    private func width(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    @discardableResult
    private func draw(
        _ text: String, font: NSFont, color: NSColor, at x: CGFloat, y: CGFloat? = nil,
        width: CGFloat, truncate: NSLineBreakMode = .byClipping
    ) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = truncate
        let string = NSAttributedString(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let natural = ceil(string.size().width)
        let used = min(natural, width)
        let top = y ?? (baselineY - font.ascender)
        string.draw(with: NSRect(x: x, y: top, width: used, height: NativeMetrics.line(font)),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return used
    }
}
