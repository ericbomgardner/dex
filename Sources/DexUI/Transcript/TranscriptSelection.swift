import DexCore
import AppKit
import SwiftUI

/// A piece of the pane a selection can run through.
///
/// Prose gives up characters; everything else — a tool row, a card, a slab of
/// code — is one character long and goes whole or not at all. That is what lets
/// a drag cross them without either kind knowing what the other is.
@MainActor
protocol SelectionRegion: AnyObject {
    var selectionPath: [Int] { get }
    var selectionLength: Int { get }
    var selectionView: NSView { get }

    func selectionText(in range: Range<Int>) -> String

    /// The same range for the apps that read HTML off the clipboard.
    func selectionHTML(in range: Range<Int>) -> String

    /// Where in the text a point lands, in this piece's own coordinates.
    func selectionIndex(at point: CGPoint) -> Int

    func showSelection(_ range: Range<Int>?)

    var selectionCell: SelectionCell? { get }
}

extension SelectionRegion {
    var selectionCell: SelectionCell? { nil }

    func selectionHTML(in range: Range<Int>) -> String {
        SelectionHTML.fragment(plain: selectionText(in: range))
    }
}

/// One pane's selection, held apart from the views that draw it.
///
/// SwiftUI selects inside a `Text` and no further, which in a transcript is one
/// paragraph: the pane is dozens of separate views, and a drag that leaves the
/// one it started in finds nothing there to carry on into. So the pieces stop
/// owning their own selection — each registers itself, the drag is resolved here
/// against all of them, and each is handed back only what of it was taken.
@MainActor
package final class TranscriptSelection {

    private struct Held {
        weak var region: (any SelectionRegion)?
    }

    /// Where a copy goes. Named rather than reached for, so a probe can drive
    /// the key without emptying whatever you had on the clipboard.
    private let pasteboard: NSPasteboard

    private var held: [ObjectIdentifier: Held] = [:]
    private var anchor: SelectionPoint?
    private var span: SelectionSpan?

    /// A click on anything that isn't prose puts the selection down. Prose has
    /// mouse handling of its own and starts a new one instead.
    private var elsewhere: Any?

    /// In reading order, which is what the copy is assembled in and what a drag
    /// through the gap between two turns is resolved against.
    private var regions: [any SelectionRegion] {
        held.values.compactMap(\.region).sorted {
            SelectionPoint(path: $0.selectionPath, offset: 0)
                < SelectionPoint(path: $1.selectionPath, offset: 0)
        }
    }

    var isEmpty: Bool { span?.isEmpty ?? true }

    /// The column draws only the rows in sight, so a span running past them
    /// takes pieces no view is holding. Asked at copy time for what of the
    /// span is off screen, it draws those rows somewhere out of sight and
    /// hands back their pieces, kept alive by `holding` until the copy is done.
    var offscreen: ((SelectionSpan) -> (pieces: [any SelectionRegion], holding: AnyObject)?)?

    /// Everything registered, in reading order. What a column drawing rows out
    /// of sight for a copy reads its pieces back from.
    var pieces: [any SelectionRegion] { regions }

    package init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    func register(_ region: any SelectionRegion) {
        held[ObjectIdentifier(region)] = Held(region: region)
        if held.count >= pruneAt { prune() }
        refresh(region)
    }

    func forget(_ region: any SelectionRegion) {
        held[ObjectIdentifier(region)] = nil
    }

    /// What a piece is holding now, for one that has just been laid out again
    /// under an open selection.
    func refresh(_ region: any SelectionRegion) {
        region.showSelection(span.flatMap { range(of: region, in: $0) })
    }

    /// Views come and go with the conversation; a weak box left behind is small
    /// but there is no other moment to drop it.
    /// Not on every forget: a switch takes down every piece in the pane, and
    /// sweeping all of them for each one made that quadratic.
    private func prune() {
        held = held.filter { $0.value.region != nil }
        pruneAt = max(256, held.count * 2)
    }

    private var pruneAt = 256

    // MARK: - Dragging

    func press(_ region: any SelectionRegion, index: Int, extending: Bool) {
        let point = SelectionPoint(path: region.selectionPath, offset: index)
        if extending, let anchor {
            set(SelectionSpan(from: anchor, to: point))
        } else {
            anchor = point
            set(nil)
        }
    }

    /// Pressed somewhere that isn't a piece at all — the pane beside the column,
    /// or the gap between two turns. Resolved against the nearest piece, which
    /// off the left of a line is the start of it.
    func press(atWindow point: CGPoint, extending: Bool) {
        guard let (region, index) = piece(atWindow: point) else { return }
        press(region, index: index, extending: extending)
    }

    /// A double or triple click, which takes a word or a line whole and drags on
    /// from whichever end the mouse leaves.
    func press(_ region: any SelectionRegion, range: Range<Int>) {
        let path = region.selectionPath
        anchor = SelectionPoint(path: path, offset: range.lowerBound)
        set(SelectionSpan(
            from: SelectionPoint(path: path, offset: range.lowerBound),
            to: SelectionPoint(path: path, offset: range.upperBound)
        ))
    }

    /// Taken with the mouse anywhere at all: the point is resolved against every
    /// piece rather than against the one the drag started in, which is the whole
    /// of what carries a selection out of a turn and into the next.
    func drag(toWindow point: CGPoint) {
        guard let anchor, let (region, index) = piece(atWindow: point) else { return }
        set(SelectionSpan(from: anchor, to: SelectionPoint(path: region.selectionPath, offset: index)))
    }

    package func selectEverything() {
        // Every row, drawn or not: the first path there could be to past the
        // last one.
        if offscreen != nil {
            let start = SelectionPoint(path: [], offset: 0)
            anchor = start
            set(SelectionSpan(from: start, to: SelectionPoint(path: [Int.max], offset: 0)))
            return
        }
        let all = regions
        guard let first = all.first, let last = all.last else { return }
        let start = SelectionPoint(path: first.selectionPath, offset: 0)
        anchor = start
        set(SelectionSpan(
            from: start,
            to: SelectionPoint(path: last.selectionPath, offset: last.selectionLength)
        ))
    }

    package func clear() {
        anchor = nil
        set(nil)
    }

    // MARK: - Copying

    @discardableResult
    func copyToPasteboard() -> Bool {
        guard let text = selectedText() else { return false }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let html = selectedHTML() { pasteboard.setString(html, forType: .html) }
        return true
    }

    /// The same selection for the apps that read HTML off the clipboard and keep
    /// the formatting: Slack, GitHub's comment box, Notes.
    func selectedHTML() -> String? {
        guard let span, !span.isEmpty else { return nil }
        let pieces = taken(in: span).compactMap { taken -> String? in
            let html = switch taken {
            case .piece(let region, let range): region.selectionHTML(in: range)
            case .table(let table): table.html
            }
            return html.isEmpty ? nil : html
        }
        return pieces.isEmpty ? nil : SelectionHTML.document(pieces)
    }

    package func selectedText() -> String? {
        guard let span, !span.isEmpty else { return nil }
        let pieces = taken(in: span).compactMap { taken -> String? in
            let text = switch taken {
            case .piece(let region, let range): region.selectionText(in: range)
            case .table(let table): table.markdown
            }
            return text.isEmpty ? nil : text
        }
        return pieces.isEmpty ? nil : pieces.joined(separator: "\n\n")
    }

    private enum Taken {
        case piece(any SelectionRegion, Range<Int>)
        case table(SelectionTable)
    }

    /// What the span takes, in reading order, with the cells of a table it
    /// crosses gathered into the table. One cell alone is only text: a drag
    /// that ends a word into a table wants the word, not a grid around it.
    private func taken(in span: SelectionSpan) -> [Taken] {
        let drawn = offscreen?(span)
        let all = drawn.map { drawn in
            (regions + drawn.pieces).sorted {
                SelectionPoint(path: $0.selectionPath, offset: 0) < SelectionPoint(path: $1.selectionPath, offset: 0)
            }
        } ?? regions
        defer { withExtendedLifetime(drawn?.holding) {} }
        var out: [Taken] = []
        var index = 0
        while index < all.count {
            let region = all[index]
            index += 1
            guard let range = range(of: region, in: span) else { continue }
            guard region.selectionCell != nil else {
                out.append(.piece(region, range))
                continue
            }

            let table = Self.table(of: region)
            let cells = all.filter { $0.selectionCell != nil && Self.table(of: $0) == table }
            while index < all.count, all[index].selectionCell != nil, Self.table(of: all[index]) == table {
                index += 1
            }
            let pieces = cells.compactMap { cell in
                cell.selectionCell.map {
                    SelectionTable.Piece(region: cell, cell: $0, range: self.range(of: cell, in: span))
                }
            }
            let reached = pieces.filter { $0.range != nil }
            if reached.count == 1, let only = reached.first, let range = only.range {
                out.append(.piece(only.region, range))
            } else {
                out.append(.table(SelectionTable(pieces: pieces)))
            }
        }
        return out
    }

    /// A cell is drawn two levels under its table: the row, then the column.
    private static func table(of region: any SelectionRegion) -> ArraySlice<Int> {
        region.selectionPath.dropLast(2)
    }

    // MARK: - Plumbing

    private func range(of region: any SelectionRegion, in span: SelectionSpan) -> Range<Int>? {
        span.range(in: region.selectionPath, length: region.selectionLength)
    }

    private func set(_ span: SelectionSpan?) {
        self.span = span
        for region in regions {
            region.showSelection(span.flatMap { range(of: region, in: $0) })
        }
        watchForAClickElsewhere(span != nil)
    }

    /// The piece under a point, or the nearest one to it: a drag through the gap
    /// between two turns, or off the end of the last line, still has to land
    /// somewhere. One the point is inside wins outright — measured by height
    /// alone, a card held to the right of the column reads as being under a
    /// reply that only shares its line. Height first, then across, so the gap
    /// between two cells of a row lands in the nearer one, not the first.
    private func piece(atWindow point: CGPoint) -> (any SelectionRegion, Int)? {
        var nearest: (region: any SelectionRegion, local: CGPoint, distance: (CGFloat, CGFloat))?

        for region in regions {
            let view = region.selectionView
            guard view.window != nil, !view.isHiddenOrHasHiddenAncestor else { continue }
            let local = view.convert(point, from: nil)
            if view.bounds.contains(local) {
                return (region, region.selectionIndex(at: local))
            }
            let distance = (
                max(0, view.bounds.minY - local.y, local.y - view.bounds.maxY),
                max(0, view.bounds.minX - local.x, local.x - view.bounds.maxX)
            )
            if nearest.map({ distance < $0.distance }) ?? true {
                nearest = (region, local, distance)
            }
        }

        guard let nearest else { return nil }
        return (nearest.region, nearest.region.selectionIndex(at: nearest.local))
    }

    private func owns(_ view: NSView?) -> Bool {
        (view as? SelectionSurface)?.owner === self
    }

    private func watchForAClickElsewhere(_ wanted: Bool) {
        if wanted, elsewhere == nil {
            elsewhere = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                MainActor.assumeIsolated {
                    // Ours, since two panes side by side each hold a selection
                    // and only one of them can be the one being started. Shift
                    // is let through: it extends what is selected, and needs
                    // the anchor this would throw away.
                    let hit = event.window?.contentView?.hitTest(event.locationInWindow)
                    let extending = event.modifierFlags.contains(.shift)
                    if self?.owns(hit) != true, !extending { self?.clear() }
                }
                return event
            }
        } else if !wanted, let monitor = elsewhere {
            NSEvent.removeMonitor(monitor)
            elsewhere = nil
        }
    }
}

// MARK: - Where a piece sits in the conversation

private struct SelectionPathKey: EnvironmentKey {
    static let defaultValue: [Int] = []
}

private struct TranscriptSelectionKey: EnvironmentKey {
    static let defaultValue: TranscriptSelection? = nil
}

extension EnvironmentValues {
    var selectionPath: [Int] {
        get { self[SelectionPathKey.self] }
        set { self[SelectionPathKey.self] = newValue }
    }

    package var transcriptSelection: TranscriptSelection? {
        get { self[TranscriptSelectionKey.self] }
        set { self[TranscriptSelectionKey.self] = newValue }
    }
}

/// Deepens the path by one, so a view can give its parts their own places
/// without knowing where it sits itself.
private struct SelectionIndex: ViewModifier {
    let index: Int

    @Environment(\.selectionPath) private var path

    func body(content: Content) -> some View {
        content.environment(\.selectionPath, path + [index])
    }
}

extension View {
    package func selectionIndex(_ index: Int) -> some View {
        modifier(SelectionIndex(index: index))
    }

    /// Marks a view that isn't prose as something a selection can run through.
    /// It goes whole, and what it puts on the clipboard is the line it draws
    /// rather than the megabyte behind it.
    func selectableWhole(_ text: String, html: String? = nil) -> some View {
        overlay(SelectionWhole(text: text, html: html))
    }
}
