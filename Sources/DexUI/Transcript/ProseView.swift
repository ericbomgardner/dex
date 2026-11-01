import DexCore
import AppKit
import SwiftUI

/// A run of prose, laid out by TextKit rather than by SwiftUI so that a drag
/// through it takes characters instead of one paragraph — and, through the
/// pane's selection, carries on into whatever is drawn after it.
struct ProseText: NSViewRepresentable {
    let source: ProseSource

    var face = ProseFace()

    /// Whether the run takes the width it is offered or only the width it needs.
    /// A reply fills the column; what you typed is a card that hugs its own
    /// longest line.
    var hugsWidth = false

    var cell: SelectionCell?

    @Environment(\.selectionPath) private var path
    @Environment(\.proseQuoteDepth) private var quoteDepth
    @Environment(\.transcriptSelection) private var selection

    func makeNSView(context: Context) -> ProseView {
        let view = ProseView()
        settle(view)
        return view
    }

    func updateNSView(_ view: ProseView, context: Context) {
        view.follow(context.environment.colorScheme)
        settle(view)
    }

    static func dismantleNSView(_ view: ProseView, coordinator: ()) {
        view.detach()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ProseView, context: Context) -> CGSize? {
        // Asked with no width at all — which is how SwiftUI asks what this would
        // like to be — the answer is the run unwrapped, the way a `Text` answers
        // it. Left to fall through to the view's own fitting size it comes back
        // a few points tall, and a whole conversation lays out as a stripe.
        guard let offered = proposal.width, offered < .infinity else {
            return nsView.used(forWidth: ProseView.unwrapped)
        }
        // Offered nothing, which is the other question: how narrow this could be
        // made. Laid out in a sliver, TextKit answers with its longest word.
        let used = nsView.used(forWidth: max(offered, 1))
        let width = hugsWidth ? min(used.width, offered) : offered
        // A cell takes the height of its row, so a press level with a
        // neighbour's second line still finds this cell nearer than that one.
        if cell != nil, let row = proposal.height, row < .infinity {
            return CGSize(width: width, height: max(used.height, row))
        }
        return CGSize(width: width, height: used.height)
    }

    private func settle(_ view: ProseView) {
        var face = face
        face.quoted = quoteDepth
        view.show(source, face: face)
        view.selectionCell = cell
        view.attach(to: selection, at: path)
    }
}

/// The view under it. Owns its own text storage rather than an `NSTextView`,
/// because most of what a text view brings — its own selection, its own
/// responder behaviour, its own idea of where a drag ends — is exactly what the
/// pane has to take back to run a selection through more than one of them.
package final class ProseView: SelectionSurface, SelectionRegion {

    private let storage = NSTextStorage()

    /// What was set, before the storage fixed its attributes: it gives each
    /// paragraph break a font, which is how a copy tells the paragraphs apart.
    private var drawn = NSAttributedString()
    private let typesetter = NSLayoutManager()
    private let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))

    /// What is laid out, so a pane redrawing itself twice a second doesn't
    /// reparse and re-typeset prose that hasn't moved.
    private var typeset: Int?
    private var mono = false
    private var markdown = false
    private var quoted = 0

    private var selected: Range<Int>?
    private var dragged = false

    package private(set) var selectionPath: [Int] = []

    package var selectionCell: SelectionCell?

    override init(frame: NSRect) {
        super.init(frame: frame)
        container.lineFragmentPadding = 0
        typesetter.addTextContainer(container)
        storage.addLayoutManager(typesetter)
        setAccessibilityRole(.staticText)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    // MARK: - Content

    func show(_ source: ProseSource, face: ProseFace) {
        mono = face.mono
        quoted = face.quoted
        if case .markdown = source { markdown = true } else { markdown = false }
        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(face)
        let key = hasher.finalize()
        guard key != typeset else { return }

        typeset = key
        drawn = Self.parsed(source, face: face, key: key)
        storage.setAttributedString(drawn)
        setAccessibilityValue(storage.string)
        invalidateIntrinsicContentSize()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        owner?.refresh(self)
    }

    /// Wide enough that nothing wraps, for the pass that asks what the run
    /// would like to be rather than what it can have.
    static let unwrapped: CGFloat = 1_000_000

    /// What a run would take at a width, laid out the way the view lays it out,
    /// on whatever thread asks — so a row can be measured before it is drawn.
    nonisolated static func size(of source: ProseSource, face: ProseFace, width: CGFloat) -> CGSize {
        let storage = NSTextStorage(attributedString: ProseMarkup.attributed(source, face: face))
        let typesetter = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        typesetter.addTextContainer(container)
        storage.addLayoutManager(typesetter)
        typesetter.ensureLayout(for: container)
        let used = typesetter.usedRect(for: container)
        return CGSize(width: ceil(used.maxX), height: ceil(used.maxY))
    }

    func used(forWidth width: CGFloat) -> CGSize {
        let measure = typeset.map { Measure(text: $0, width: width) }
        if let measure, let size = Self.measured[measure] { return size }
        resize(to: width)
        typesetter.ensureLayout(for: container)
        let used = typesetter.usedRect(for: container)
        let size = CGSize(width: ceil(used.maxX), height: ceil(used.maxY))
        if let measure { Self.remember(size, for: measure) }
        return size
    }

    // MARK: - Shared

    /// Kept across views rather than in each: a switch builds every row's view
    /// anew, and SwiftUI asks each its size at several widths, every one of
    /// them a fresh typeset of text that was on screen a moment ago.
    private struct Measure: Hashable {
        let text: Int
        let width: CGFloat
    }

    private static var measured: [Measure: CGSize] = [:]
    private static var parsedText: [Int: NSAttributedString] = [:]
    private static let keeps = 20_000

    private static func remember(_ size: CGSize, for measure: Measure) {
        if measured.count >= keeps { measured.removeAll(keepingCapacity: true) }
        measured[measure] = size
    }

    private static func parsed(_ source: ProseSource, face: ProseFace, key: Int) -> NSAttributedString {
        if let text = parsedText[key] { return text }
        let text = ProseMarkup.attributed(source, face: face)
        if parsedText.count >= keeps / 4 { parsedText.removeAll(keepingCapacity: true) }
        parsedText[key] = text
        return text
    }

    private func resize(to width: CGFloat) {
        guard container.size.width != width else { return }
        container.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    package override func layout() {
        super.layout()
        guard container.size.width != bounds.width else { return }
        resize(to: bounds.width)
        needsDisplay = true
    }

    /// Measuring leaves the run laid out for the last width SwiftUI asked about,
    /// which in a grid is often not the width the cell was given.
    private func fitBounds() {
        guard bounds.width > 0 else { return }
        resize(to: bounds.width)
    }

    // MARK: - Drawing

    package override func draw(_ dirtyRect: NSRect) {
        fitBounds()
        drawSelection()
        let glyphs = typesetter.glyphRange(for: container)
        typesetter.drawBackground(forGlyphRange: glyphs, at: .zero)
        typesetter.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    }

    private func drawSelection() {
        guard let selected, !selected.isEmpty else { return }

        let characters = NSRange(location: selected.lowerBound, length: selected.count)
        let glyphs = typesetter.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
        let tint = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        tint.setFill()
        typesetter.enumerateEnclosingRects(
            forGlyphRange: glyphs,
            withinSelectedGlyphRange: glyphs,
            in: container
        ) { rect, _ in
            rect.fill()
        }
    }

    // MARK: - Selection

    package var selectionLength: Int { storage.length }

    var selectionView: NSView { self }

    package func selectionText(in range: Range<Int>) -> String {
        ProseMarkup.plain((storage.string as NSString).substring(with: clamped(range)))
    }

    /// Alone, a slab of code or a stretch of one paragraph is its characters;
    /// with anything else, code is fenced and prose keeps its markup.
    func selectionMarkdown(in range: Range<Int>, alone: Bool) -> String {
        let raw = selectionText(in: range)
        if alone, mono || !markdown || !raw.trimmingCharacters(in: .newlines).contains("\n") { return raw }
        let markup = if mono {
            SelectionMarkdown.fenced(raw)
        } else if markdown {
            SelectionMarkdown.fragment(drawn.attributedSubstring(from: clamped(range)))
        } else {
            raw
        }
        return SelectionMarkdown.quoted(markup, depth: quoted)
    }

    /// A slab of code goes as one preformatted block; prose goes by its attributes.
    func selectionHTML(in range: Range<Int>) -> String {
        let piece = drawn.attributedSubstring(from: clamped(range))
        let html = mono ? SelectionHTML.preformatted(piece.string) : SelectionHTML.fragment(piece)
        guard !html.isEmpty else { return html }
        return String(repeating: "<blockquote>", count: quoted) + html + String(repeating: "</blockquote>", count: quoted)
    }

    private func clamped(_ range: Range<Int>) -> NSRange {
        let from = min(max(0, range.lowerBound), storage.length)
        let to = min(max(from, range.upperBound), storage.length)
        return NSRange(location: from, length: to - from)
    }

    package func selectionIndex(at point: CGPoint) -> Int {
        guard storage.length > 0 else { return 0 }
        fitBounds()
        // A measure answered from the cache leaves nothing laid out to read.
        typesetter.ensureLayout(for: container)

        // Off the top or the bottom of the run entirely: a drag passing through
        // takes all of it or none, rather than stopping at the nearest line.
        let used = typesetter.usedRect(for: container)
        if point.y < used.minY { return 0 }
        // Off the left of a cell is the start of the row, however far down it.
        if point.y > used.maxY { return selectionCell != nil && point.x < 0 ? 0 : storage.length }

        var fraction: CGFloat = 0
        let index = typesetter.characterIndex(
            for: point,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: &fraction
        )
        return min(storage.length, fraction > 0.5 ? index + 1 : index)
    }

    func showSelection(_ range: Range<Int>?) {
        guard range != selected else { return }
        selected = range
        needsDisplay = true
    }

    func attach(to selection: TranscriptSelection?, at path: [Int]) {
        guard owner !== selection || selectionPath != path else { return }
        owner?.forget(self)
        hold(selection)
        selectionPath = path
        if window != nil { selection?.register(self) }
    }

    func detach() {
        owner?.forget(self)
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { owner?.forget(self) } else { owner?.register(self) }
    }

    // MARK: - Mouse

    package override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragged = false

        let index = selectionIndex(at: convert(event.locationInWindow, from: nil))
        switch event.clickCount {
        case 1:
            owner?.press(self, index: index, extending: event.modifierFlags.contains(.shift))
        case 2:
            owner?.press(self, range: word(around: index))
        default:
            owner?.press(self, range: line(around: index))
        }
    }

    package override func mouseDragged(with event: NSEvent) {
        dragged = true
        owner?.drag(toWindow: event.locationInWindow)
        autoscroll(with: event)
    }

    package override func mouseUp(with event: NSEvent) {
        guard !dragged, let (url, _) = link(at: convert(event.locationInWindow, from: nil)) else { return }
        NSWorkspace.shared.open(url)
    }

    package override func menu(for event: NSEvent) -> NSMenu? {
        guard let (url, index) = link(at: convert(event.locationInWindow, from: nil)) else {
            return super.menu(for: event)
        }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(LinkMenuItem("Open Link", url: url) { NSWorkspace.shared.open($0) })
        menu.addItem(LinkMenuItem(url.namesLocalFile ? "Copy Path" : "Copy Link", url: url) { url in
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(url.namesLocalFile ? url.path : url.absoluteString, forType: .string)
        })
        if selected?.contains(index) == true {
            menu.addItem(.separator())
            menu.addItem(selectionItem("Copy", #selector(copy(_:)), enabled: true))
        }
        return menu
    }

    private func word(around index: Int) -> Range<Int> {
        let text = storage.string as NSString
        guard text.length > 0 else { return 0..<0 }
        let range = storage.doubleClick(at: min(index, text.length - 1))
        return range.location..<(range.location + range.length)
    }

    private func line(around index: Int) -> Range<Int> {
        let text = storage.string as NSString
        guard text.length > 0 else { return 0..<0 }
        let range = text.paragraphRange(for: NSRange(location: min(index, text.length - 1), length: 0))
        return range.location..<(range.location + range.length)
    }

    private func link(at point: CGPoint) -> (url: URL, index: Int)? {
        guard storage.length > 0 else { return nil }
        fitBounds()
        let index = typesetter.characterIndex(
            for: point,
            in: container,
            fractionOfDistanceBetweenInsertionPoints: nil
        )
        guard index < storage.length else { return nil }
        let glyph = typesetter.glyphIndexForCharacter(at: index)
        let box = typesetter.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
        guard box.contains(point) else { return nil }
        switch storage.attribute(.link, at: index, effectiveRange: nil) {
        case let url as URL: return (url, index)
        case let text as String: return URL(string: text).map { ($0, index) }
        default: return nil
        }
    }

    package override func resetCursorRects() {
        super.resetCursorRects()
        guard storage.length > 0 else { return }
        fitBounds()

        storage.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil else { return }
            let glyphs = typesetter.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            typesetter.enumerateEnclosingRects(
                forGlyphRange: glyphs,
                withinSelectedGlyphRange: glyphs,
                in: container
            ) { rect, _ in
                self.addCursorRect(rect, cursor: .pointingHand)
            }
        }
    }

    // MARK: - Keys

    package override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    package override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }
}

private extension URL {
    /// A bare path in markdown parses with no scheme at all, not as a file URL.
    var namesLocalFile: Bool { isFileURL || scheme == nil }
}

private final class LinkMenuItem: NSMenuItem {
    private let url: URL
    private let perform: (URL) -> Void

    init(_ title: String, url: URL, perform: @escaping (URL) -> Void) {
        self.url = url
        self.perform = perform
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not from a nib") }

    @objc private func fire() { perform(url) }
}
