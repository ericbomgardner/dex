import DexCore
import DexUI
import AppKit
import SwiftUI

/// What a drag across a transcript actually takes. Run as
/// `DexProbes --selection-probe`; anything it finds wrong fails the run.
///
/// The reading is the one thing no unit test can reach: a selection that starts
/// in one view, runs through a slab of code drawn by another, and ends in a
/// third. The span arithmetic is pinned in `SelectionSpanTests`; what is driven
/// here is everything between the mouse and that arithmetic — hit testing,
/// TextKit's idea of which character a point lands on, and the order the pieces
/// come back in.
@MainActor
enum SelectionProbe {

    private static let opening = """
        ## Reading the transcript

        The pane draws a reply as blocks, and every block used to be a view of \
        its own with a selection of its own.

        - one paragraph at a time
        - and never past the end of it
        """

    private static let code = "swift build\nswift test"

    /// Drawn as a grid of runs, one a cell, and put back together as a table
    /// when a drag takes more than one of them.
    private static let table = """
        | tool | what it does |
        | --- | --- |
        | drag | takes characters |
        |  |  |
        | wrap | \(Array(repeating: "a cell long enough to wrap", count: 8).joined(separator: " ")) |
        """

    private static let closing = "That is what this changes."

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)

        var report: [String: Any] = [:]
        var failed = false

        let (within, withinHeld) = insideOnePiece()
        report["insideOnePiece"] = within
        failed = failed || !withinHeld

        let (across, acrossHeld) = acrossFourPieces()
        report["acrossFourPieces"] = across
        failed = failed || !acrossHeld

        let (cell, cellHeld) = insideOneCell()
        report["insideOneCell"] = cell
        failed = failed || !cellHeld

        let (cells, cellsHeld) = acrossCells()
        report["acrossCells"] = cells
        failed = failed || !cellsHeld

        let (beside, besideHeld) = besideAShortCell()
        report["besideAShortCell"] = beside
        failed = failed || !besideHeld

        let (margin, marginHeld) = fromTheMargin()
        report["fromTheMargin"] = margin
        failed = failed || !marginHeld

        let (padded, paddedHeld) = fromACardsPadding()
        report["fromACardsPadding"] = padded
        failed = failed || !paddedHeld

        let (pressed, pressHeld) = buttonsInFront()
        report["buttonsInFront"] = pressed
        failed = failed || !pressHeld

        let (copied, copyHeld) = command("c")
        report["copyKey"] = copied
        failed = failed || !copyHeld

        let (whole, wholeHeld) = copiesWhatIsOutOfSight()
        report["copiesWhatIsOutOfSight"] = whole
        failed = failed || !wholeHeld

        let (away, awayHeld) = copiesAfterScrollingAway()
        report["copiesAfterScrollingAway"] = away
        failed = failed || !awayHeld

        let (shifted, shiftHeld) = shiftClickedFromTheMargin()
        report["shiftClickedFromTheMargin"] = shifted
        failed = failed || !shiftHeld

        let (menu, menuHeld) = rightClicked()
        report["rightClicked"] = menu
        failed = failed || !menuHeld

        let (linked, linkHeld) = rightClickedOnALink()
        report["rightClickedOnALink"] = linked
        failed = failed || !linkHeld

        report["passed"] = !failed
        let data = try? JSONSerialization.data(withJSONObject: report,
                                               options: [.prettyPrinted, .sortedKeys])
        FileHandle.standardOutput.write(data ?? Data())
        FileHandle.standardOutput.write(Data("\n".utf8))
        return failed ? 1 : 0
    }

    // MARK: - The readings

    /// The old behaviour, still expected to work: a drag that never leaves the
    /// paragraph it started in takes part of that paragraph.
    private static func insideOnePiece() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard let prose = staged.prose.first else { return (["error": "nothing drawn"], false) }

        drag(from: (prose, CGPoint(x: 30, y: 6)), to: (prose, CGPoint(x: 200, y: 6)), in: staged)

        let taken = staged.selection.selectedText() ?? ""
        let whole = ProseMarkup.plain(text(of: prose))
        let held = !taken.isEmpty && whole.contains(taken) && taken.count < whole.count

        return (["took": taken, "held": held], held)
    }

    /// The reading this is all for. The drag starts inside the first reply, runs
    /// through a slab of code and a table, and ends inside the last reply — and
    /// comes back as the tail of the first, the whole of both things in the
    /// middle, and the head of the last.
    private static func acrossFourPieces() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard staged.prose.count == 3, staged.cells.count == 8 else {
            return (["error": "expected three runs of prose and four cells",
                     "prose": staged.prose.count,
                     "cells": staged.cells.count], false)
        }

        let opening = staged.prose[0]
        let closing = staged.prose[2]
        let start = (opening, CGPoint(x: 120, y: 6))
        let end = (closing, CGPoint(x: 90, y: 6))

        drag(from: start, to: end, in: staged)
        let forwards = staged.selection.selectedText() ?? ""

        drag(from: end, to: start, in: staged)
        let backwards = staged.selection.selectedText() ?? ""

        // Copied as markdown: the drag starts part way into the heading, so
        // the first piece is "## " and the end of it, then the rest of the
        // reply as it was written.
        let heading = "Reading the transcript"
        let restOfTheFirst = "\n\nThe pane draws a reply as blocks, and every block used to be a view of "
            + "its own with a selection of its own.\n\n- one paragraph at a time\n- and never past the end of it"
        let slab = "\n\n```\n" + code + "\n```"
        let grid = "\n\n" + table + "\n\n"

        let pieces = [restOfTheFirst, slab, grid].map { forwards.range(of: $0) }
        let parts = pieces.compactMap { $0 }.count
        let ordered = parts == 3 && zip(pieces, pieces.dropFirst()).allSatisfy { $0!.upperBound == $1!.lowerBound }
        let headTaken = pieces[0].map { String(forwards[..<$0.lowerBound]) } ?? ""
        let tailTaken = pieces[2].map { String(forwards[$0.upperBound...]) } ?? ""

        let takesTheTailOfTheFirst = ordered && headTaken.hasPrefix("## ")
            && headTaken.count > 3 && heading.hasSuffix(headTaken.dropFirst(3))
            && headTaken.count - 3 < heading.count
        let takesTheSlabWhole = ordered
        let takesTheGridWhole = ordered
        let takesTheHeadOfTheLast = ordered && !tailTaken.isEmpty && Self.closing.hasPrefix(tailTaken)
            && tailTaken.count < Self.closing.count
        let heldEitherWay = forwards == backwards

        let held = takesTheTailOfTheFirst && takesTheSlabWhole && takesTheGridWhole
            && takesTheHeadOfTheLast && heldEitherWay

        return ([
            "took": forwards,
            "pieces": parts,
            "takesTheTailOfTheFirst": takesTheTailOfTheFirst,
            "takesTheSlabWhole": takesTheSlabWhole,
            "takesTheGridWhole": takesTheGridWhole,
            "takesTheHeadOfTheLast": takesTheHeadOfTheLast,
            "heldEitherWay": heldEitherWay,
        ], held)
    }

    /// Pressed inside a cell, which before cells were runs of their own was a
    /// press on nothing at all.
    private static func insideOneCell() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard staged.cells.count == 8 else { return (["error": "no cells drawn"], false) }

        let cell = staged.cells[3]
        drag(from: (cell, CGPoint(x: 10, y: 6)), to: (cell, CGPoint(x: 60, y: 6)), in: staged)

        let taken = staged.selection.selectedText() ?? ""
        let whole = text(of: cell)
        let held = !taken.isEmpty && whole.contains(taken) && taken.count < whole.count

        return (["took": taken, "held": held], held)
    }

    /// From part way into the second heading to part way into the first cell
    /// under it: the header goes whole, the row keeps both its columns, and
    /// the cell the drag never reached is there and empty.
    private static func acrossCells() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard staged.cells.count == 8 else { return (["error": "no cells drawn"], false) }

        drag(from: (staged.cells[1], CGPoint(x: 30, y: 6)),
             to: (staged.cells[2], CGPoint(x: 16, y: 6)),
             in: staged)

        let taken = staged.selection.selectedText() ?? ""
        let lines = taken.components(separatedBy: "\n")
        let shaped = lines.count == 3
            && lines[0] == "| tool | what it does |"
            && lines[1] == "| --- | --- |"
            && lines[2].hasPrefix("| dr") && lines[2].hasSuffix(" |  |")
            && !lines[2].contains("drag")

        let copied = key("c", in: staged.window)
        let html = staged.pasteboard.string(forType: .html) ?? ""
        let tabled = html.contains("<thead><tr><th>") && html.contains("tool")
            && html.contains("<td></td></tr></tbody></table>")
        let held = shaped && copied && tabled

        return (["took": taken, "html": html, "shaped": shaped, "tabled": tabled], held)
    }

    /// Pressed in the margin level with the second line of a cell that wraps,
    /// beside one that doesn't: the short cell is the nearer, and is where the
    /// selection starts.
    private static func besideAShortCell() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard let margin = staged.margin, staged.cells.count == 8, staged.prose.count == 3 else {
            return (["error": "nothing to press in"], false)
        }

        let short = staged.cells[6]
        let edge = short.convert(CGPoint(x: 0, y: ChromeType.Reading.bodySize * 2), to: nil)
        press(margin, atWindow: CGPoint(x: edge.x - ChromeMetrics.readingInset / 2, y: edge.y), in: staged)
        dragOn(to: (staged.prose[2], CGPoint(x: 90, y: 6)), in: staged, from: margin)

        let taken = staged.selection.selectedText() ?? ""
        let rows = taken.components(separatedBy: "\n").filter { $0.hasPrefix("|") }
        let held = rows.count == 3 && rows[2].hasPrefix("| wrap | a cell")
        return (["took": String(taken.prefix(120)), "held": held], held)
    }

    /// Started beside a line rather than on it. Pressing in the margin has to
    /// land where pressing at the very start of that line would, or selecting
    /// whole lines still means hitting the first character.
    private static func fromTheMargin() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard let margin = staged.margin, staged.prose.count >= 3 else {
            return (["error": "nothing to drag from"], false)
        }

        let first = staged.prose[0]
        let last = (staged.prose[2], CGPoint(x: 90, y: 6))
        let onTheLine = CGPoint(x: 0, y: 6)

        drag(from: (first, onTheLine), to: last, in: staged)
        let fromTheText = staged.selection.selectedText() ?? ""

        // The same height, out in the pane to the left of the column.
        let beside = first.convert(onTheLine, to: nil)
        press(margin, atWindow: CGPoint(x: beside.x - ChromeMetrics.readingInset / 2, y: beside.y),
              in: staged)
        dragOn(to: last, in: staged, from: margin)
        let fromTheMargin = staged.selection.selectedText() ?? ""

        let held = !fromTheMargin.isEmpty && fromTheMargin == fromTheText
        return ([
            "took": String(fromTheMargin.prefix(40)),
            "sameAsTheLineStart": held,
        ], held)
    }

    /// Started in the tinted inset around a slab of code. The tint is drawn, not
    /// a thing to click, so the press has to fall through it to the margin and
    /// land where pressing at the start of the slab's first line would.
    private static func fromACardsPadding() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard let margin = staged.margin, staged.prose.count == 3 else {
            return (["error": "nothing to drag from"], false)
        }

        let slab = staged.prose[1]
        let last = (staged.prose[2], CGPoint(x: 90, y: 6))
        let onTheLine = CGPoint(x: 0, y: 6)

        // First, so no earlier drag has left an anchor for this one to reuse.
        let edge = slab.convert(onTheLine, to: nil)
        press(margin, atWindow: CGPoint(x: edge.x - ChromeMetrics.detailInset / 2, y: edge.y), in: staged)
        // A margin, the column's or the one behind the slab's own row: either
        // starts the selection at the nearest piece.
        let caught = staged.window.firstResponder is MarginView
        dragOn(to: last, in: staged, from: margin)
        let fromThePadding = staged.selection.selectedText() ?? ""

        drag(from: (slab, onTheLine), to: last, in: staged)
        let fromTheText = staged.selection.selectedText() ?? ""

        let held = caught && !fromThePadding.isEmpty && fromThePadding == fromTheText
        return ([
            "took": String(fromThePadding.prefix(40)),
            "caughtByTheMargin": caught,
            "sameAsTheLineStart": held,
        ], held)
    }

    /// The price of catching a drag behind the whole conversation: the pane it
    /// is laid under is full of things that take a click — every tool row opens
    /// on one. A view behind SwiftUI's own content must not win the hit test
    /// against it.
    private static func buttonsInFront() -> ([String: Any], Bool) {
        let counted = Counter()
        let window = staged(Rows(counted: counted))
        defer { window.orderOut(nil) }

        guard let root = window.contentView else { return (["error": "nothing drawn"], false) }
        // On the row's first line, in from the column's leading edge.
        let column = min(ChromeMetrics.readingMeasure, root.bounds.width - 2 * ChromeMetrics.readingInset)
        let x = (root.bounds.width - column) / 2 + 6
        click(atWindow: root.convert(CGPoint(x: x, y: ChromeMetrics.readingInset + 6), to: nil), in: window)

        return (["opened": counted.count], counted.count == 1)
    }

    @MainActor
    private final class Counter {
        var count = 0
    }

    private struct Rows: View {
        let counted: Counter

        var body: some View {
            TranscriptColumn(rows: [
                ColumnRow(
                    id: "button", content: 1, place: 0,
                    view: AnyView(Button("open") { counted.count += 1 }.buttonStyle(.plain))
                ),
            ])
            .environment(\.transcriptSelection, TranscriptSelection())
        }
    }

    private static func staged(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 300),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: view)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        return window
    }

    /// The same passage taken without a drag: pressed at one end, shift-pressed
    /// at the other, which is how anyone takes a long one rather than dragging
    /// it past the bottom of the pane. The caret has to end up here — a
    /// highlight on screen with ⌘C going to the composer is worse than no
    /// selection at all.
    private static func shiftClickedFromTheMargin() -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard let margin = staged.margin, staged.prose.count >= 3 else {
            return (["error": "nothing to press in"], false)
        }

        beside(staged.prose[0], in: staged, holding: [])
        beside(staged.prose[2], in: staged, holding: .shift)

        let selected = staged.selection.selectedText() ?? ""
        let took = key("c", in: staged.window)
        let landed = staged.pasteboard.string(forType: .string)

        let held = !selected.isEmpty && took && landed == selected
            && staged.window.firstResponder === margin

        return ([
            "selected": selected.count,
            "onTheClipboard": landed?.count ?? 0,
            "held": held,
        ], held)
    }

    /// A conversation longer than the pane, taken whole and taken in part: the
    /// column draws only the rows in sight, so everything past them has to be
    /// drawn for the copy — and come back exactly as the rows would read, in
    /// order, with nothing doubled where a row was both on screen and drawn.
    private static func copiesWhatIsOutOfSight() -> ([String: Any], Bool) {
        let pasteboard = NSPasteboard(name: .init("DexSelectionProbe"))
        let selection = TranscriptSelection(pasteboard: pasteboard)
        let lines = (0..<60).map { "Paragraph \($0) of a long conversation, kept short so the count is the reading." }
        let rows = lines.enumerated().map { reply($1, place: $0, id: "long-\($0)") }
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: TranscriptColumn(rows: rows).environment(\.transcriptSelection, selection))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        defer { window.orderOut(nil) }

        let drawn = (found(in: window.contentView ?? NSView()) as [ProseView]).filter { !$0.isHiddenOrHasHiddenAncestor }
        selection.selectEverything()
        let everything = selection.selectedText() ?? ""
        let whole = everything == lines.joined(separator: "\n\n")

        // From the start of the sixth row to the end of the fiftieth, the
        // first of them long since scrolled away by the time the second is
        // pressed.
        guard let scroll = (found(in: window.contentView ?? NSView()) as [NSScrollView]).first else {
            return (["error": "no scroll view"], false)
        }
        func row(_ place: Int) -> ProseView? {
            (found(in: window.contentView ?? NSView()) as [ProseView])
                .first { !$0.isHiddenOrHasHiddenAncestor && $0.selectionPath == [place, 0] }
        }
        func bringIntoSight(_ place: Int) {
            for _ in 0..<40 {
                if let prose = row(place), let document = scroll.documentView {
                    let frame = prose.convert(prose.bounds, to: document)
                    if scroll.contentView.bounds.contains(frame) { return }
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, frame.minY - 40)))
                } else {
                    let step: CGFloat = place > 25 ? 300 : -300
                    scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, scroll.contentView.bounds.minY + step)))
                }
                scroll.reflectScrolledClipView(scroll.contentView)
                spin(times: 2)
            }
        }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
        spin()
        bringIntoSight(5)
        guard let sixth = row(5) else { return (["error": "sixth row not drawn"], false) }
        let press = sixth.convert(CGPoint(x: 0, y: 6), to: nil)
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouse(phase, at: press, in: window) { window.sendEvent(event) }
        }
        spin(times: 2)
        bringIntoSight(49)
        guard let fiftieth = row(49) else { return (["error": "fiftieth row not drawn"], false) }
        // Out of sight, though still drawn: it holds the caret, so the column
        // keeps it rather than hand its view to another row.
        let sixthGone = row(5).map { prose in
            !scroll.contentView.bounds.intersects(prose.convert(prose.bounds, to: scroll.contentView))
        } ?? true
        let end = fiftieth.convert(CGPoint(x: fiftieth.bounds.width - 1, y: fiftieth.bounds.height - 2), to: nil)
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouse(phase, at: end, in: window, modifiers: .shift) { window.sendEvent(event) }
        }
        spin(times: 2)
        let part = selection.selectedText() ?? ""
        let expected = lines[5...49].joined(separator: "\n\n")
        let partHeld = part == expected

        let held = whole && partHeld && drawn.count < lines.count && sixthGone
        return ([
            "rowsDrawn": drawn.count,
            "everything": everything.count,
            "everythingWhole": whole,
            "part": part.count,
            "partExpected": expected.count,
            "partHeld": partHeld,
            "anchorRowScrolledAway": sixthGone,
        ], held)
    }

    /// A selection made in a row, then the row scrolled far out of sight: ⌘C
    /// still copies it. The key goes to the view the selection was started in,
    /// so the column must not hand that view to another row. Once for a row
    /// drawn natively and once for one drawn by SwiftUI.
    private static func copiesAfterScrollingAway() -> ([String: Any], Bool) {
        let pasteboard = NSPasteboard(name: .init("DexSelectionProbe"))
        let selection = TranscriptSelection(pasteboard: pasteboard)
        let lines = (0..<60).map { "Paragraph \($0) of a long conversation, kept short so the count is the reading." }
        var rows = lines.enumerated().map { reply($1, place: $0, id: "away-\($0)") }
        rows[6] = ColumnRow(
            id: "away-slab", content: ["slab", "away"].hashValue, place: 6,
            view: AnyView(MonoSlab(text: "a slab of code, drawn by SwiftUI").padding(.top, ChromeMetrics.itemGap))
        )
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 400),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: TranscriptColumn(rows: rows).environment(\.transcriptSelection, selection))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        defer { window.orderOut(nil) }
        guard let scroll = (found(in: window.contentView ?? NSView()) as [NSScrollView]).first else {
            return (["error": "no scroll view"], false)
        }

        var readings: [String: Any] = [:]
        var held = true
        for (name, path) in [("native", [5, 0]), ("swiftUI", [6, 0])] {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: 150))
            scroll.reflectScrolledClipView(scroll.contentView)
            spin()
            guard let prose = (found(in: window.contentView ?? NSView()) as [ProseView])
                .first(where: { !$0.isHiddenOrHasHiddenAncestor && $0.selectionPath == path }) else {
                readings[name] = "row not drawn"; held = false; continue
            }
            press(prose, atWindow: prose.convert(CGPoint(x: 2, y: 6), to: nil), in: Staged(
                window: window, selection: selection, pasteboard: pasteboard, prose: [], cells: [], margin: nil
            ))
            dragOn(to: (prose, CGPoint(x: 120, y: 6)), in: Staged(
                window: window, selection: selection, pasteboard: pasteboard, prose: [], cells: [], margin: nil
            ), from: prose)
            let selected = selection.selectedText() ?? ""
            scroll.contentView.scroll(to: NSPoint(x: 0, y: scroll.documentView?.frame.height ?? 10_000))
            scroll.reflectScrolledClipView(scroll.contentView)
            spin()
            pasteboard.clearContents()
            let took = key("c", in: window)
            let landed = pasteboard.string(forType: .string) ?? ""
            let ok = !selected.isEmpty && took && landed == selected
            readings[name] = ["selected": selected, "copied": landed, "held": ok]
            held = held && ok
        }
        return (readings, held)
    }

    /// Pressed in the pane to the left of a run, at the height of its first line.
    private static func beside(
        _ prose: ProseView,
        in staged: Staged,
        holding modifiers: NSEvent.ModifierFlags
    ) {
        let edge = prose.convert(CGPoint(x: 0, y: 6), to: nil)
        let point = CGPoint(x: edge.x - ChromeMetrics.readingInset / 2, y: edge.y)
        if let event = mouse(.leftMouseDown, at: point, in: staged.window, modifiers: modifiers) {
            staged.window.sendEvent(event)
        }
        if let event = mouse(.leftMouseUp, at: point, in: staged.window, modifiers: modifiers) {
            staged.window.sendEvent(event)
        }
        spin(times: 2)
    }

    /// The last link, and the only one the pane can't answer for itself: ⌘C has
    /// to reach the run the drag left the selection in. It is offered to every
    /// view in the window before the menu ever sees it, which is why the answer
    /// is refused unless the caret is ours.
    private static func command(_ key: String) -> ([String: Any], Bool) {
        let staged = stage()
        defer { staged.window.orderOut(nil) }

        guard staged.prose.count >= 3 else { return (["error": "nothing drawn"], false) }

        drag(from: (staged.prose[0], CGPoint(x: 120, y: 6)),
             to: (staged.prose[2], CGPoint(x: 90, y: 6)),
             in: staged)

        let took = self.key(key, in: staged.window)
        let landed = staged.pasteboard.string(forType: .string)
        let html = staged.pasteboard.string(forType: .html) ?? ""
        // The paragraphs and the list come apart only if the copy reads the
        // breaks as set, not as the text storage refonted them.
        let formatted = ["<b>", "<pre>", "<table>", "</p>\n<p>The pane", "<ul><li>one paragraph"]
            .allSatisfy { html.contains($0) }
        let held = took && landed == staged.selection.selectedText() && formatted

        return (["taken": took, "onTheClipboard": landed?.count ?? 0, "html": html.count, "formatted": formatted, "held": held], held)
    }

    private static func key(_ characters: String, in window: NSWindow) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: 8
        ) else { return false }

        return window.performKeyEquivalent(with: event)
    }

    /// Right-clicked through the window, everywhere a reader might: the prose,
    /// the margin beside it, a slab drawn by SwiftUI and a plain SwiftUI label.
    /// Each offers Copy and Select All, and the Copy offered takes what was
    /// selected. That a right-click leaves the selection be is seen in the app:
    /// sending one here would open the menu.
    private static func rightClicked() -> ([String: Any], Bool) {
        let staged = stage(extra: ColumnRow(
            id: "label", content: "label".hashValue, place: 4,
            view: AnyView(Text("A label SwiftUI draws on its own").padding(.top, ChromeMetrics.itemGap))
        ))
        defer { staged.window.orderOut(nil) }

        guard let margin = staged.margin, staged.prose.count == 3,
              let label = (found(in: staged.window.contentView ?? NSView()) as [NSView])
                .first(where: { String(describing: type(of: $0)).contains("Hosting") && $0 !== staged.window.contentView
                    && $0.convert($0.bounds, to: nil).minY < staged.prose[2].convert(staged.prose[2].bounds, to: nil).minY })
        else { return (["error": "nothing drawn"], false) }

        drag(from: (staged.prose[0], CGPoint(x: 120, y: 6)),
             to: (staged.prose[2], CGPoint(x: 90, y: 6)),
             in: staged)
        let selected = staged.selection.selectedText() ?? ""

        let opening = staged.prose[0].convert(CGPoint(x: 160, y: 6), to: nil)
        let beside = CGPoint(x: 8, y: opening.y)
        let slab = staged.prose[1].convert(CGPoint(x: 20, y: 6), to: nil)
        let text = label.convert(CGPoint(x: label.bounds.midX, y: label.bounds.maxY - 12), to: nil)

        var places: [String: Any] = [:]
        var held = !selected.isEmpty
        for (name, point) in [("prose", opening), ("margin", beside), ("slab", slab), ("label", text)] {
            let items = menu(at: point, in: staged.window)
            places[name] = items
            held = held && items == ["Copy", "Select All"]
        }

        staged.pasteboard.clearContents()
        let item = margin.menu(for: mouse(.rightMouseDown, at: beside, in: staged.window)!)?.item(withTitle: "Copy")
        if let item, let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
        let copied = staged.pasteboard.string(forType: .string) == selected
        held = held && copied

        staged.selection.clear()
        let empty = margin.menu(for: mouse(.rightMouseDown, at: beside, in: staged.window)!)
        let greyed = empty?.item(withTitle: "Copy")?.isEnabled == false
            && empty?.item(withTitle: "Select All")?.isEnabled == true
        held = held && greyed

        return (["places": places, "copied": copied, "greyedWhenEmpty": greyed, "held": held], held)
    }

    /// Over a link that is inside the selection, the link's own items and Copy;
    /// over one outside it, the link's alone. Clicked on the right half of the
    /// link's last character too, where the caret a press would leave is
    /// already past the link.
    private static func rightClickedOnALink() -> ([String: Any], Bool) {
        let selection = TranscriptSelection(pasteboard: NSPasteboard(name: .init("DexSelectionProbe")))
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 300),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: TranscriptColumn(rows: [
            reply("[docs](https://example.com) and more after the link", place: 0),
        ]).environment(\.transcriptSelection, selection))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()
        defer { window.orderOut(nil) }

        guard let prose = (found(in: window.contentView ?? NSView()) as [ProseView])
            .first(where: { !$0.isHiddenOrHasHiddenAncestor })
        else { return (["error": "nothing drawn"], false) }

        let link = prose.convert(CGPoint(x: 10, y: 6), to: nil)
        // "docs" is four characters; the last of them ends where "s" does.
        let end = prose.convert(lastHalf(of: 3, in: prose), to: nil)
        let alone = menu(at: link, in: window)

        // From just after the link to the end, so the link itself is not taken.
        prose.mouseDown(with: mouse(.leftMouseDown, at: end, in: window)!)
        prose.mouseDragged(with: mouse(.leftMouseDragged, at: prose.convert(CGPoint(x: prose.bounds.maxX - 2, y: 6), to: nil), in: window)!)
        let after = menu(at: end, in: window)

        selection.selectEverything()
        let inside = menu(at: link, in: window)
        let insideAtTheEnd = menu(at: end, in: window)

        let linkOnly = ["Open Link", "Copy Link"]
        let withCopy = linkOnly + ["Copy"]
        let held = alone == linkOnly && after == linkOnly
            && inside == withCopy && insideAtTheEnd == withCopy
        return (["outsideSelection": alone, "selectedFromJustAfter": after,
                 "insideSelection": inside, "insideAtItsEnd": insideAtTheEnd, "held": held], held)
    }

    /// Just right of the middle of a character, where a press puts the caret
    /// after it.
    private static func lastHalf(of character: Int, in prose: ProseView) -> CGPoint {
        var x: CGFloat = 0
        while prose.selectionIndex(at: CGPoint(x: x, y: 6)) <= character, x < prose.bounds.maxX { x += 0.5 }
        return CGPoint(x: x + 0.5, y: 6)
    }

    /// What a right-click at a point would pop up: hit tested through the
    /// window, then asked up the responder chain the way `rightMouseDown` asks.
    /// Not opened: a context menu tracks modally and would hold the run.
    private static func menu(at point: CGPoint, in window: NSWindow) -> [String] {
        guard let event = mouse(.rightMouseDown, at: point, in: window) else { return [] }
        var responder: NSResponder? = window.contentView?.hitTest(
            window.contentView?.superview?.convert(point, from: nil) ?? point
        )
        while let current = responder {
            if let view = current as? NSView, let menu = view.menu(for: event) {
                return menu.items.filter { !$0.isSeparatorItem && !$0.isHidden }.map(\.title)
            }
            responder = current.nextResponder
        }
        return []
    }

    // MARK: - Driving

    private struct Staged {
        let window: NSWindow
        let selection: TranscriptSelection
        let pasteboard: NSPasteboard
        let prose: [ProseView]
        let cells: [ProseView]
        let margin: MarginView?
    }

    /// The conversation as the pane draws it, in the real column: the two
    /// replies are all running text and drawn natively, the slab and the table
    /// are SwiftUI's — so every drag here crosses from one kind to the other.
    private static func conversation(_ selection: TranscriptSelection, extra: ColumnRow? = nil) -> some View {
        TranscriptColumn(rows: [
            reply(opening, place: 0),
            ColumnRow(
                id: "slab", content: ["slab", code].hashValue, place: 1,
                view: AnyView(MonoSlab(text: code).padding(.top, ChromeMetrics.itemGap))
            ),
            ColumnRow(
                id: "table", content: ["table", table].hashValue, place: 2,
                view: AnyView(MarkdownText(blocks: Markdown.blocks(in: table)).padding(.top, ChromeMetrics.itemGap))
            ),
            reply(closing, place: 3),
        ] + (extra.map { [$0] } ?? []))
        .environment(\.transcriptSelection, selection)
    }

    private static func reply(_ text: String, place: Int, id: String? = nil) -> ColumnRow {
        let blocks = Markdown.blocks(in: text)
        let lead = place > 0 ? ChromeMetrics.itemGap : 0
        return ColumnRow(
            id: id ?? "reply-\(place)", content: ["reply", text, "\(lead)"].hashValue, place: place,
            view: AnyView(MarkdownText(blocks: blocks).padding(.top, lead)),
            native: .reply(blocks), lead: lead
        )
    }

    private static func stage(extra: ColumnRow? = nil) -> Staged {
        // Its own board: the reading is where a copy lands, and the general one
        // is holding whatever you last copied yourself.
        let pasteboard = NSPasteboard(name: .init("DexSelectionProbe"))
        let selection = TranscriptSelection(pasteboard: pasteboard)
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 700, height: 700),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // Off every screen and invisible with it, the way the card probe stages
        // one: AppKit pulls a titled window back onto a screen.
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: conversation(selection, extra: extra))
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        spin()

        let root = window.contentView ?? NSView()
        // Down the pane, since the column adds its cells in no order of its own.
        let prose = (found(in: root) as [ProseView])
            .filter { $0.selectionCell == nil && !$0.isHiddenOrHasHiddenAncestor && $0.window != nil }
            .sorted { $0.convert($0.bounds, to: nil).maxY > $1.convert($1.bounds, to: nil).maxY }
        return Staged(
            window: window,
            selection: selection,
            pasteboard: pasteboard,
            prose: prose,
            cells: (found(in: root) as [ProseView]).filter { $0.selectionCell != nil },
            margin: (found(in: root) as [MarginView]).first
        )
    }

    /// In the order they are drawn, which for these is the order they are read.
    private static func found<Kind: NSView>(in view: NSView) -> [Kind] {
        var kind: [Kind] = []
        if let match = view as? Kind { kind.append(match) }
        for child in view.subviews { kind += found(in: child) }
        return kind
    }

    private static func drag(
        from start: (ProseView, CGPoint),
        to end: (ProseView, CGPoint),
        in staged: Staged
    ) {
        press(start.0, atWindow: start.0.convert(start.1, to: nil), in: staged)
        dragOn(to: end, in: staged, from: start.0)
    }

    /// Pressed through the window rather than at the view, so the hit testing is
    /// driven too — which for the margin is the whole of the reading.
    private static func press(_ view: NSView, atWindow point: CGPoint, in staged: Staged) {
        if let event = mouse(.leftMouseDown, at: point, in: staged.window) {
            staged.window.sendEvent(event)
        }
        spin(times: 1)
    }

    private static func click(atWindow point: CGPoint, in window: NSWindow) {
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = mouse(phase, at: point, in: window) { window.sendEvent(event) }
        }
        spin(times: 2)
    }

    private static func dragOn(to end: (ProseView, CGPoint), in staged: Staged, from view: NSView) {
        let up = end.0.convert(end.1, to: nil)
        if let event = mouse(.leftMouseDragged, at: up, in: staged.window) {
            view.mouseDragged(with: event)
        }
        if let event = mouse(.leftMouseUp, at: up, in: staged.window) {
            view.mouseUp(with: event)
        }
        spin(times: 2)
    }

    private static func mouse(
        _ phase: NSEvent.EventType,
        at point: CGPoint,
        in window: NSWindow,
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: phase,
            location: point,
            modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: phase == .leftMouseUp || phase == .rightMouseUp ? 0 : 1
        )
    }

    private static func text(of prose: ProseView) -> String {
        prose.selectionText(in: 0..<prose.selectionLength)
    }

    private static func spin(times: Int = 6) {
        for _ in 0..<times {
            RunLoop.main.run(until: Date().addingTimeInterval(0.03))
        }
    }
}
