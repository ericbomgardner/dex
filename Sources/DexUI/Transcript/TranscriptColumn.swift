import DexCore
import AppKit
import SwiftUI

/// One row of a conversation, for the column to draw when it is in sight.
package struct ColumnRow {
    let id: String

    /// What the row draws, hashed. A row whose content and width have not
    /// changed keeps the height it was measured at, in this transcript or the
    /// next time it is opened.
    let content: Int

    /// Its place in the selection, as `selectionIndex` gives a piece.
    let place: Int

    /// The row as SwiftUI draws it. Drawn on screen only where there is no
    /// native form; always there for drawing it out of sight for a copy.
    let view: AnyView

    /// The row drawn in AppKit, for the kinds that have a native form, under
    /// the space the SwiftUI view would have put above itself.
    var native: NativeRow? = nil
    var lead: CGFloat = 0

    package init(id: String, content: Int, place: Int, view: AnyView, native: NativeRow? = nil, lead: CGFloat = 0) {
        self.id = id
        self.content = content
        self.place = place
        self.view = view
        self.native = native
        self.lead = lead
    }
}

/// Whether the reader is far enough up for the way back to be offered, and the
/// way back itself. Held apart from the column so the button over it is
/// SwiftUI's to draw.
@MainActor
@Observable
final class ColumnControl {
    fileprivate(set) var faraway = false
    @ObservationIgnored fileprivate weak var view: ColumnView?

    func holdEnd() { view?.holdEnd() }
}

/// The conversation a pane reads: a scroll view that draws only the rows in
/// sight, from a few cells it moves and refills, with every row's height known
/// before it is drawn. Switching to a long transcript costs the rows on screen,
/// not the length of it.
package struct TranscriptColumn: View {
    let rows: [ColumnRow]

    /// Counted up by the composer every time the reader speaks to this session.
    /// The transcript holds the end from there until they go back up it.
    var sends = 0

    /// The transcript the rows were read from. A change is a switch: the place
    /// in the one left is kept, and the one opened goes back to its own.
    var transcript: String?

    var places: TranscriptPlaces?

    /// The row to bring into the middle of the pane, once per value.
    var reveal: TranscriptReveal?

    package init(
        rows: [ColumnRow],
        sends: Int = 0,
        transcript: String? = nil,
        places: TranscriptPlaces? = nil,
        reveal: TranscriptReveal? = nil
    ) {
        self.rows = rows
        self.sends = sends
        self.transcript = transcript
        self.places = places
        self.reveal = reveal
    }

    @State private var control = ColumnControl()

    package var body: some View {
        ColumnHost(rows: rows, sends: sends, transcript: transcript, places: places, reveal: reveal, control: control)
            .overlay(alignment: .bottom) {
                if control.faraway {
                    JumpToEnd { control.holdEnd() }
                        .padding(.bottom, ChromeMetrics.readingInset)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: control.faraway)
    }

    /// A line's worth. Where the end is measured to, a reader a few points off
    /// it was reading the end.
    package static let slack: CGFloat = 4
}

private struct ColumnHost: NSViewRepresentable {
    let rows: [ColumnRow]
    let sends: Int
    let transcript: String?
    let places: TranscriptPlaces?
    let reveal: TranscriptReveal?
    let control: ColumnControl

    func makeNSView(context: Context) -> ColumnView {
        let view = ColumnView()
        control.view = view
        view.control = control
        return view
    }

    func updateNSView(_ view: ColumnView, context: Context) {
        view.update(
            rows: rows,
            sends: sends,
            transcript: transcript,
            places: places,
            reveal: reveal,
            environment: context.environment
        )
    }

    static func dismantleNSView(_ view: ColumnView, coordinator: ()) {
        view.leave()
    }
}

/// What a cell draws: one row, laid out in the reading column, with the pane's
/// environment handed down — a cell is a hosting view of its own, and inherits
/// nothing from the SwiftUI it sits in.
private struct CellRoot: View {
    let row: ColumnRow?
    let environment: EnvironmentValues
    let reportsHeight: Bool
    let report: (String, CGFloat) -> Void

    var body: some View {
        if let row {
            row.view
                // Its own state, not the last row's: a cell refilled with
                // another row would otherwise open the folds this one had.
                .id(row.id)
                .selectionIndex(row.place)
                .frame(maxWidth: ChromeMetrics.readingMeasure, alignment: .leading)
                .padding(.horizontal, ChromeMetrics.readingInset)
                .frame(maxWidth: .infinity, alignment: .top)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    if reportsHeight { report(row.id, height) }
                }
                // Top of the cell, and as tall as the cell — but not for the
                // measurer, which offers all the height there is to learn
                // what the row would take.
                .frame(maxHeight: reportsHeight ? .infinity : nil, alignment: .top)
                // A press on nothing in the row is a press in the margin. The
                // hosting view would otherwise take it for itself.
                .background { if reportsHeight { SelectionMargin() } }
                .lineSpacing(ChromeMetrics.readingLead)
                .environment(\.self, environment)
        }
    }
}

private typealias Cell = NSHostingView<CellRoot>

@MainActor
package final class ColumnView: NSView {

    weak var control: ColumnControl?

    private let scroll = NSScrollView()
    private let document = MarginView()

    private var rows: [ColumnRow] = []
    private var index: [String: Int] = [:]
    private var heights: [CGFloat] = []
    /// Whether each height was measured or is a guess standing in until it is.
    private var exact: [Bool] = []
    private var tops: [CGFloat] = [0]

    private var cells: [String: NSView] = [:]
    private var pool: [Cell] = []
    private var nativePool: [NativeCell] = []
    private var environment = EnvironmentValues()

    /// Whether the reader is at the end, which is what decides what happens
    /// when anything changes height: at the end stays at the end, anywhere else
    /// keeps the row at the top of the pane where it is.
    private var atEnd = true
    /// A place being returned to that the transcript has not reached yet.
    private var pending: TranscriptPlaces.Place?
    /// Set while the column moves the scroll view itself, so only the reader
    /// moving it counts as the reader moving.
    private var adjusting = 0
    /// Where the reader was before a change that has not been laid out yet.
    private var held: Anchor?
    /// The clip view's top as the column last left it, and the inset over it.
    private var laidY: CGFloat = 0
    private var insets = NSEdgeInsetsZero

    private var transcript: String?
    private var places: TranscriptPlaces?
    private var sends: Int?
    private var revealed: TranscriptReveal?
    private var measuring = false
    private var laidWidth: CGFloat?

    /// The row last pressed, and where its top was on screen. A row that
    /// changes height because it was pressed — a fold opened — stays where it
    /// was under the pointer, whatever else the column would have held still.
    private var pressed: (id: String, onScreen: CGFloat, at: ContinuousClock.Instant)?
    private var presses: Any?

    private enum Anchor {
        case end
        case row(String, into: CGFloat)
        case offset(CGFloat)
    }

    init() {
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.contentView.postsBoundsChangedNotifications = true
        addSubview(scroll)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not from a nib") }

    package override var isFlipped: Bool { true }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let presses { NSEvent.removeMonitor(presses) }
        presses = nil
        guard window != nil else { return }
        presses = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.noticePress(event) }
            return event
        }
    }

    private func noticePress(_ event: NSEvent) {
        guard event.window === window, !rows.isEmpty, tops.count == rows.count + 1 else { return }
        // Only a press that landed in this column: a card laid over it, or
        // another column in the same window, is pressed somewhere else.
        guard let hit = window?.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: self) else { return }
        let clip = scroll.contentView
        let point = clip.convert(event.locationInWindow, from: nil)
        guard clip.bounds.contains(point) else { return }
        let row = row(at: point.y)
        pressed = (rows[row].id, tops[row] - clip.bounds.minY, .now)
    }

    /// Holding the pressed row where it is, if the press turned a fold a
    /// moment ago — not for anything else that happens to a row that was
    /// clicked, which at the end of a working session is most of them.
    private func pressedAnchor(changing id: String) -> Anchor? {
        guard let pressed, pressed.id == id, ContinuousClock.now - pressed.at < .seconds(2),
              let turned = RowExpansions.shared.turnedAt, turned >= pressed.at
        else { return nil }
        return .row(id, into: -pressed.onScreen)
    }

    /// Where a row's top is on screen, and how tall it is, for a probe.
    package func onScreen(_ id: String) -> (top: CGFloat, height: CGFloat)? {
        guard let row = index[id], tops.count == rows.count + 1 else { return nil }
        return (tops[row] - scroll.contentView.bounds.minY, heights[row])
    }

    package var rowIDs: [String] { rows.map(\.id) }
    package var scrollView: NSScrollView { scroll }

    // MARK: - From SwiftUI

    func update(
        rows: [ColumnRow],
        sends: Int,
        transcript: String?,
        places: TranscriptPlaces?,
        reveal: TranscriptReveal?,
        environment: EnvironmentValues
    ) {
        self.places = places
        self.environment = environment
        let selection = environment.transcriptSelection
        document.hold(selection)
        selection?.offscreen = { [weak self] span in self?.drawn(offscreen: span) }

        var anchor = held ?? currentAnchor()
        held = nil

        if transcript != self.transcript {
            remember()
            self.transcript = transcript
            pending = transcript.flatMap { places?[$0] }
            atEnd = pending == nil
            anchor = atEnd ? .end : .offset(pending?.offset ?? 0)
        }
        if let last = self.sends, sends != last {
            atEnd = true
            pending = nil
            anchor = .end
        } else if let pressed, let old = index[pressed.id],
                  let now = rows.first(where: { $0.id == pressed.id }), now.content != self.rows[old].content,
                  let held = pressedAnchor(changing: pressed.id) {
            anchor = held
            atEnd = false
        }
        self.sends = sends

        take(rows)
        if let place = pending, let resolved = resolve(place) {
            pending = nil
            anchor = resolved
        }

        if let reveal, reveal != revealed, let row = index[reveal.itemID] {
            measure(around: row)
            stack()
            atEnd = false
            pending = nil
            let middle = tops[row] + heights[row] / 2 - scroll.contentView.bounds.height / 2
            anchor = .offset(middle)
        }
        revealed = reveal

        measureNear(anchor)
        lay(anchor, refill: true)
        measureTheRest()
    }

    /// The reader's place in the transcript being left, for coming back to it.
    func leave() {
        remember()
        environment.transcriptSelection?.offscreen = nil
    }

    func holdEnd() {
        atEnd = true
        pending = nil
        lay(.end)
    }

    // MARK: - Rows and heights

    private static var known: [Key: CGFloat] = [:]

    /// What a height depends on, which is not which row it is: a row
    /// regrouped under another id, or one the same as another, keeps it.
    private struct Key: Hashable {
        let content: Int
        let width: CGFloat
    }

    /// The text column's width, which is all a row's height depends on. Capped
    /// by the reading measure, so a window wider than that resizes without a
    /// single row being measured again.
    private var width: CGFloat {
        min(ChromeMetrics.readingMeasure, scroll.contentSize.width - 2 * ChromeMetrics.readingInset)
    }

    private func key(_ row: ColumnRow) -> Key {
        Key(content: row.content, width: width)
    }

    private func take(_ new: [ColumnRow]) {
        let before = Dictionary(zip(rows.map(\.id), heights), uniquingKeysWith: { first, _ in first })
        rows = new
        index = Dictionary(zip(new.map(\.id), new.indices), uniquingKeysWith: { first, _ in first })
        heights = []
        exact = []
        heights.reserveCapacity(new.count)
        exact.reserveCapacity(new.count)
        for row in new {
            if let height = Self.known[key(row)] {
                heights.append(height)
                exact.append(true)
            } else {
                heights.append(before[row.id] ?? Self.guess)
                exact.append(false)
            }
        }
    }

    private static let guess: CGFloat = 60

    /// Every native row not yet measured, measured off the main thread at
    /// once — the bulk of a transcript, so most of it has its real height
    /// within a beat of opening rather than a batch at a time.
    private var measuringAway = false

    /// One job at a time: what it finds goes into the shared heights whatever
    /// the rows have become by the time it lands, so nothing it measures is
    /// thrown away, and whatever is still unmeasured then is the next job.
    private func measureNativeAway() {
        // Not before the column has a width to measure at, and not through a
        // live resize, whose end starts it again at the width it ends on.
        guard !measuringAway, width > 0, !inLiveResize else { return }
        let jobs = rows.indices.filter { !exact[$0] && rows[$0].native != nil }
            .map { (key: key(rows[$0]), row: rows[$0].native!, lead: rows[$0].lead) }
        guard !jobs.isEmpty else { return }
        measuringAway = true
        let width = width
        let metrics = NativeMetrics.current
        Task.detached(priority: .userInitiated) { [weak self] in
            let heights = jobs.map { $0.lead + $0.row.height(width: width, metrics: metrics) }
            await MainActor.run { [weak self] in
                self?.landed(zip(jobs.map(\.key), heights).map { ($0, $1) })
            }
        }
    }

    private func landed(_ measured: [(Key, CGFloat)]) {
        measuringAway = false
        for (key, height) in measured { Self.remember(height, for: key) }
        let anchor = held ?? currentAnchor()
        held = nil
        var moved = false
        for row in rows.indices where !exact[row] {
            guard let height = Self.known[key(rows[row])] else { continue }
            exact[row] = true
            if heights[row] != height { heights[row] = height; moved = true }
        }
        if moved { lay(anchor) }
        measureNativeAway()
    }

    private lazy var measurer = NSHostingController(rootView: CellRoot(
        row: nil, environment: EnvironmentValues(), reportsHeight: false, report: { _, _ in }
    ))

    private func measure(_ row: Int) {
        guard !exact[row] else { return }
        if let native = rows[row].native {
            let height = rows[row].lead + native.height(width: width, metrics: NativeMetrics.current)
            heights[row] = height
            exact[row] = true
            Self.remember(height, for: key(rows[row]))
            return
        }
        measurer.rootView = CellRoot(row: rows[row], environment: environment, reportsHeight: false) { _, _ in }
        let height = ceil(measurer.sizeThatFits(in: CGSize(
            width: scroll.contentSize.width, height: .greatestFiniteMagnitude
        )).height)
        heights[row] = height
        exact[row] = true
        Self.remember(height, for: key(rows[row]))
    }

    private static func remember(_ height: CGFloat, for key: Key) {
        if known.count > 100_000 { known.removeAll(keepingCapacity: true) }
        known[key] = height
    }

    private func measure(around row: Int) {
        let reach = scroll.contentView.bounds.height
        var filled: CGFloat = 0
        var at = row
        while at < rows.count, filled < reach {
            measure(at)
            filled += heights[at]
            at += 1
        }
        filled = 0
        at = row - 1
        while at >= 0, filled < reach / 2 {
            measure(at)
            filled += heights[at]
            at -= 1
        }
    }

    /// Exact heights for what will be in sight once the anchor is applied, so
    /// the first frame is drawn at the size it stays.
    private func measureNear(_ anchor: Anchor) {
        guard !rows.isEmpty else { return }
        switch anchor {
        case .end:
            let reach = scroll.contentView.bounds.height * 1.5
            var filled: CGFloat = 0
            var at = rows.count - 1
            while at >= 0, filled < reach {
                measure(at)
                filled += heights[at]
                at -= 1
            }
        case .row(let id, _):
            if let row = index[id] { measure(around: row) }
        case .offset(let y):
            stack()
            measure(around: row(at: y))
        }
    }

    /// The rest, a few at a time between frames, nearest the reader first —
    /// for the scroller's sake and for a jump anywhere landing measured.
    private func measureTheRest() {
        measureNativeAway()
        guard !measuring, rows.indices.contains(where: { !exact[$0] && rows[$0].native == nil }) else { return }
        measuring = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            measuring = false
            let anchor = currentAnchor()
            let budget = ContinuousClock.now + .milliseconds(4)
            let near = row(at: scroll.contentView.bounds.midY)
            var low = near, high = near + 1
            while ContinuousClock.now < budget, low >= 0 || high < rows.count {
                if high < rows.count { if rows[high].native == nil { measure(high) }; high += 1 }
                if low >= 0 { if rows[low].native == nil { measure(low) }; low -= 1 }
            }
            lay(anchor)
            measureTheRest()
        }
    }

    /// A row on screen saying what it came to. Drawn by the same view the
    /// measurer used, so this is a correction for what changed since — a fold
    /// opened, an answer arrived — rather than a second opinion.
    private func reported(_ id: String, _ height: CGFloat) {
        guard let row = index[id], abs(heights[row] - height) > 0.5 else { return }
        if let anchor = pressedAnchor(changing: id) {
            held = anchor
            atEnd = false
        }
        if held == nil { held = currentAnchor() }
        heights[row] = height
        exact[row] = true
        Self.remember(height, for: key(rows[row]))
        needsLayout = true
    }

    // MARK: - Laying out

    private func stack() {
        tops = [ChromeMetrics.readingInset]
        tops.reserveCapacity(rows.count + 1)
        for height in heights { tops.append(tops[tops.count - 1] + height) }
    }

    private var documentHeight: CGFloat {
        max(tops[tops.count - 1] + ChromeMetrics.readingInset, scroll.contentView.bounds.height)
    }

    /// The row the point falls in, or the nearest one.
    private func row(at y: CGFloat) -> Int {
        guard !rows.isEmpty else { return 0 }
        var low = 0, high = rows.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if tops[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func currentAnchor(at top: CGFloat? = nil) -> Anchor {
        if atEnd { return .end }
        let y = top ?? scroll.contentView.bounds.minY
        guard !rows.isEmpty, tops.count == rows.count + 1 else { return .offset(y) }
        let row = row(at: y)
        return .row(rows[row].id, into: y - tops[row])
    }

    private func lay(_ anchor: Anchor, refill: Bool = false) {
        stack()
        adjusting += 1
        defer { adjusting -= 1 }

        let size = NSSize(width: scroll.contentSize.width, height: documentHeight)
        if document.frame.size != size { document.setFrameSize(size) }

        let viewport = scroll.contentView.bounds.height
        let bottom = max(0, documentHeight - viewport)
        let target: CGFloat = switch anchor {
        case .end: bottom
        case .row(let id, let into): index[id].map { tops[$0] + into } ?? scroll.contentView.bounds.minY
        case .offset(let y): y
        }
        let y = min(max(0, target), bottom)
        if scroll.contentView.bounds.minY != y {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
        place(refill: refill)
        if case .end = anchor {} else if pending == nil {
            atEnd = documentHeight - scroll.contentView.bounds.maxY <= TranscriptColumn.slack
        }
        laidY = scroll.contentView.bounds.minY
        insets = scroll.contentInsets
        noticeDistance()
    }

    /// Cells on every row in sight and a little past it, from a pool that stays
    /// in the window — a cell taken out and put back is a hosting view leaving
    /// the window and joining it again, which is most of what a table spends.
    private func place(refill: Bool) {
        let visible = scroll.contentView.bounds.insetBy(dx: 0, dy: -Self.overscan)
        var wanted: Set<String> = []
        if !rows.isEmpty, tops.count == rows.count + 1 {
            for row in row(at: visible.minY)...row(at: visible.maxY) where tops[row + 1] > visible.minY {
                wanted.insert(rows[row].id)
            }
        }
        // The row holding the caret stays drawn wherever it has scrolled to:
        // ⌘C and the rest of a drag go to the view a selection was started
        // in, and a cell refilled with another row would take them with it.
        if let holder = cells.first(where: { holdsCaret($0.value) })?.key, index[holder] != nil {
            wanted.insert(holder)
        }

        for (id, cell) in cells {
            // Gone from sight, or turned into the other kind of row — a run
            // opened is SwiftUI's, and shut again is AppKit's.
            let kept = wanted.contains(id) && index[id].map { (rows[$0].native != nil) == (cell is NativeCell) } == true
            if !kept { retire(id, cell) }
        }

        for id in wanted {
            guard let row = index[id] else { continue }
            let frame = NSRect(x: 0, y: tops[row], width: document.bounds.width, height: heights[row])
            if let cell = cells[id] {
                if refill { fill(cell, row) }
                if cell.frame != frame { cell.frame = frame }
                continue
            }
            let cell: NSView
            if rows[row].native != nil {
                if let reused = nativePool.popLast() {
                    cell = reused
                } else {
                    cell = NativeCell(frame: frame)
                    document.addSubview(cell)
                }
            } else if let reused = pool.popLast() {
                cell = reused
            } else {
                let host = Cell(rootView: root(for: row))
                // Placed by frame; the sizes it would work out for Auto Layout
                // are a measurement nobody reads.
                host.sizingOptions = []
                document.addSubview(host)
                cell = host
            }
            fill(cell, row)
            cell.isHidden = false
            cell.frame = frame
            cells[id] = cell
        }
    }

    private func holdsCaret(_ cell: NSView) -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: cell)
    }

    private func fill(_ cell: NSView, _ row: Int) {
        if let native = cell as? NativeCell, let form = rows[row].native {
            native.show(form, lead: rows[row].lead, place: rows[row].place, environment: environment) { fold in
                RowExpansions.shared.toggle(fold)
            }
        } else if let host = cell as? Cell {
            host.rootView = root(for: row)
        }
    }

    private func retire(_ id: String, _ cell: NSView) {
        cells[id] = nil
        // The caret goes to the column's own margin first, which answers ⌘C
        // for the same selection. Hidden with the caret in it, the cell sends
        // AppKit looking for the next key view, which asks the pane's SwiftUI
        // for its responders in the middle of the update that called this.
        if holdsCaret(cell) { window?.makeFirstResponder(document) }
        cell.isHidden = true
        if let native = cell as? NativeCell {
            native.clear()
            nativePool.append(native)
        } else if let host = cell as? Cell {
            host.rootView = CellRoot(row: nil, environment: environment, reportsHeight: false) { _, _ in }
            pool.append(host)
        }
    }

    private static let overscan: CGFloat = 200

    private func root(for row: Int) -> CellRoot {
        CellRoot(row: rows[row], environment: environment, reportsHeight: true) { [weak self] id, height in
            self?.reported(id, height)
        }
    }

    private func noticeDistance() {
        guard let control else { return }
        let bounds = scroll.contentView.bounds
        let gap = documentHeight - bounds.maxY
        let far = control.faraway ? gap > bounds.height / 2 : gap > bounds.height
        guard far != control.faraway else { return }
        DispatchQueue.main.async { [weak control] in control?.faraway = far }
    }

    // MARK: - AppKit

    package override func setFrameSize(_ size: NSSize) {
        if held == nil { held = currentAnchor() }
        adjusting += 1
        super.setFrameSize(size)
        adjusting -= 1
        needsLayout = true
    }

    package override func layout() {
        super.layout()
        if scroll.frame != bounds {
            adjusting += 1
            scroll.frame = bounds
            adjusting -= 1
        }
        var anchor = held ?? currentAnchor()
        held = nil
        if let place = pending {
            if let resolved = resolve(place) {
                pending = nil
                anchor = resolved
            } else {
                anchor = .offset(place.offset)
            }
        }
        // Only the text's width moves a height, and past the reading measure
        // a wider pane doesn't move that.
        let widthMoved = laidWidth != width
        if widthMoved { take(rows) }
        laidWidth = width
        measureNear(anchor)
        lay(anchor, refill: widthMoved)
        // Through a live resize, only what is in sight: the rest once it ends.
        if !inLiveResize { measureTheRest() }
    }

    package override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        measureTheRest()
    }

    @objc private func scrolled() {
        guard adjusting == 0 else { return }
        // AppKit insets a scroll view under the titlebar once it is in the
        // window, after the column has placed the reader. The clip view moving
        // for that is not the reader moving.
        if !NSEdgeInsetsEqual(scroll.contentInsets, insets) {
            lay(pending.map { .offset($0.offset) } ?? currentAnchor(at: laidY))
            return
        }
        let bounds = scroll.contentView.bounds
        atEnd = documentHeight - bounds.maxY <= TranscriptColumn.slack
        pending = nil
        // Rows coming into sight still on a guess are measured as they come,
        // and the row at the top held still while they settle.
        let reach = bounds.insetBy(dx: 0, dy: -Self.overscan)
        var guessed = false
        if !rows.isEmpty, tops.count == rows.count + 1 {
            for row in row(at: reach.minY)...row(at: reach.maxY) where !exact[row] {
                measure(row)
                guessed = true
            }
        }
        if guessed {
            lay(currentAnchor())
        } else {
            adjusting += 1
            place(refill: false)
            adjusting -= 1
            laidY = bounds.minY
        }
        noticeDistance()
    }

    // MARK: - Places

    private func remember() {
        guard let transcript, let places, !rows.isEmpty, tops.count == rows.count + 1 else { return }
        if atEnd || pending != nil {
            if atEnd { places[transcript] = nil }
            return
        }
        let y = scroll.contentView.bounds.minY
        let row = row(at: y)
        places[transcript] = TranscriptPlaces.Place(row: rows[row].id, into: y - tops[row], offset: y)
    }

    /// Where a kept place lands in the rows as they are now: on its row, or —
    /// a row since renamed or gone — on its offset once there is enough
    /// transcript to reach it. Nil while there isn't.
    private func resolve(_ place: TranscriptPlaces.Place) -> Anchor? {
        if index[place.row] != nil { return .row(place.row, into: place.into) }
        // Not before the pane has a height: with none, any transcript reaches
        // any offset.
        guard scroll.contentView.bounds.height > 0 else { return nil }
        // An offset means something only over rows at their real heights.
        for row in rows.indices where !exact[row] {
            stack()
            if tops[row] > place.offset + scroll.contentView.bounds.height { break }
            measure(row)
        }
        stack()
        let end = max(0, documentHeight - scroll.contentView.bounds.height)
        return end >= place.offset - TranscriptColumn.slack ? .offset(place.offset) : nil
    }

    // MARK: - Copying what is out of sight

    /// The rows a span takes that have no cell, drawn in a window nobody sees,
    /// so a copy is assembled from the same views a drag through them would
    /// have been — not from a second reading of the transcript that could
    /// drift from what the pane shows.
    private func drawn(offscreen span: SelectionSpan) -> (pieces: [any SelectionRegion], holding: AnyObject)? {
        let first = span.start.path.first ?? Int.min
        let last = span.end.path.first ?? Int.max
        let missing = rows.filter { $0.place >= first && $0.place <= last && cells[$0.id] == nil }
        guard !missing.isEmpty else { return nil }

        let selection = TranscriptSelection()
        var environment = environment
        environment.transcriptSelection = selection
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: scroll.contentSize.width, height: 100),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: VStack(spacing: 0) {
            ForEach(missing, id: \.id) { row in
                CellRoot(row: row, environment: environment, reportsHeight: false) { _, _ in }
            }
        })
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (selection.pieces, [window, selection, host] as NSArray)
    }
}
