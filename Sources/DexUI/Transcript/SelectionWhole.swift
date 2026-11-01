import AppKit
import SwiftUI

/// The mark a selection crosses on anything that isn't prose: a tool row, a
/// card, a slab of code. It draws nothing until the drag reaches it and takes no
/// clicks at all, so the buttons under it are still buttons.
struct SelectionWhole: NSViewRepresentable {
    let text: String
    var html: String?

    @Environment(\.selectionPath) private var path
    @Environment(\.transcriptSelection) private var selection

    func makeNSView(context: Context) -> WholeSelectionView {
        let view = WholeSelectionView()
        settle(view)
        return view
    }

    func updateNSView(_ view: WholeSelectionView, context: Context) {
        settle(view)
    }

    static func dismantleNSView(_ view: WholeSelectionView, coordinator: ()) {
        view.detach()
    }

    /// An overlay is offered its content's size, and takes it — there is nothing
    /// here with a size of its own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: WholeSelectionView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    private func settle(_ view: WholeSelectionView) {
        view.text = text
        view.html = html
        view.attach(to: selection, at: path)
    }
}

final class WholeSelectionView: NSView, SelectionRegion {

    var text = ""
    var html: String?

    private var isTaken = false
    private weak var owner: TranscriptSelection?

    private(set) var selectionPath: [Int] = []

    override var isFlipped: Bool { true }

    /// Transparent to the mouse: the card under this has its own disclosure
    /// triangles and buttons, and a drag that reaches here started in prose.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: - Selection

    /// One character long. The span is asked the same question a paragraph is
    /// asked, and any answer at all means the drag crossed this.
    var selectionLength: Int { 1 }

    var selectionView: NSView { self }

    func selectionText(in range: Range<Int>) -> String { text }

    func selectionHTML(in range: Range<Int>) -> String {
        html ?? SelectionHTML.fragment(plain: text)
    }

    /// Half way down is where it starts counting as crossed, the way a character
    /// is taken once the mouse is past the middle of it.
    func selectionIndex(at point: CGPoint) -> Int {
        point.y > bounds.midY ? 1 : 0
    }

    func showSelection(_ range: Range<Int>?) {
        let taken = range != nil
        guard taken != isTaken else { return }
        isTaken = taken
        needsDisplay = true
    }

    func attach(to selection: TranscriptSelection?, at path: [Int]) {
        guard owner !== selection || selectionPath != path else { return }
        owner?.forget(self)
        owner = selection
        selectionPath = path
        if window != nil { selection?.register(self) }
    }

    func detach() {
        owner?.forget(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { owner?.forget(self) } else { owner?.register(self) }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard isTaken else { return }

        // Over the card rather than behind it, since a card draws a fill of its
        // own that would hide anything underneath — and resolved against the
        // appearance before it is asked for an alpha, since a system colour
        // asked the other way round comes back drawing nothing at all.
        let tint = window?.isKeyWindow == true
            ? NSColor.selectedTextBackgroundColor
            : NSColor.unemphasizedSelectedTextBackgroundColor
        (tint.usingColorSpace(.sRGB) ?? tint).withAlphaComponent(Self.overCard).setFill()
        NSBezierPath(
            roundedRect: bounds,
            xRadius: ChromeMetrics.promptCorner,
            yRadius: ChromeMetrics.promptCorner
        ).fill()
    }

    private static let overCard: CGFloat = 0.45
}
