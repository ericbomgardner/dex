import DexCore
import DexUI
import AppKit
import SwiftUI

/// What opening a fold does to the reader's place. Run as
/// `DexProbes --fold-probe <session>`: a shut tool run near the end of the real
/// pane is pressed open and pressed shut again, at the end of the transcript
/// and scrolled back up it, and the row pressed has to stay where it was under
/// the pointer every time.
@MainActor
enum FoldProbe {

    static func run() -> Int32 {
        NSApplication.shared.setActivationPolicy(.prohibited)
        guard let id = CommandLine.arguments.drop(while: { $0 != "--fold-probe" }).dropFirst().first else { return 2 }
        let feed = TranscriptFeed()
        let attachment = PaneAttachment(hostKey: id, workingDirectory: nil, sessionID: id)
        let window = NSWindow(
            contentRect: NSRect(x: -6000, y: -6000, width: 900, height: 900),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.alphaValue = 0
        window.contentView = NSHostingView(rootView: TranscriptPane(
            attachment: attachment, feed: feed, isWorking: false, isLive: false, source: LocalTranscriptSource()
        ))
        window.makeKeyAndOrderFront(nil)
        let began = ContinuousClock.now
        while feed.items.isEmpty, ContinuousClock.now - began < .seconds(30) { spin(1) }
        spin(20)

        let columns: [ColumnView] = found(in: window.contentView!)
        guard let column = columns.first else { return 2 }
        var failed = false
        for scrolledBack in [false, true] {
            if scrolledBack {
                let clip = column.scrollView.contentView
                clip.scroll(to: NSPoint(x: 0, y: max(0, clip.bounds.minY - 400)))
                column.scrollView.reflectScrolledClipView(clip)
                spin(10)
            }
            // The lowest shut run in sight.
            let headers: [NativeHeader] = found(in: column).filter { header in
                guard !header.isHiddenOrHasHiddenAncestor, case .run = header.content else { return false }
                let frame = header.convert(header.bounds, to: column.scrollView.contentView)
                return column.scrollView.contentView.bounds.contains(frame)
            }
            guard let header = headers.max(by: {
                $0.convert($0.bounds, to: nil).minY > $1.convert($1.bounds, to: nil).minY
            }), let cell = header.superview as? NativeCell, let rowID = rowID(of: cell, in: column) else {
                // Nothing to press in this stretch of the transcript.
                print("SKIP \(scrolledBack ? "scrolled back" : "at the end"): no shut run in sight")
                continue
            }
            let press = header.convert(NSPoint(x: 40, y: header.bounds.midY), to: nil)
            guard let before = column.onScreen(rowID) else { return 2 }

            click(press, in: window)
            spin(20)
            guard let open = column.onScreen(rowID) else { return 2 }
            click(press, in: window)
            spin(20)
            guard let shut = column.onScreen(rowID) else { return 2 }

            let opened = open.height > before.height + 10
            let stayedOpening = abs(open.top - before.top) <= 0.5
            let stayedShutting = abs(shut.top - before.top) <= 0.5
            let shutAgain = abs(shut.height - before.height) <= 0.5
            let held = opened && stayedOpening && stayedShutting && shutAgain
            failed = failed || !held
            print(String(
                format: "%@ %@: top %.1f → %.1f → %.1f, height %.1f → %.1f → %.1f",
                held ? "OK  " : "FAIL", scrolledBack ? "scrolled back" : "at the end",
                before.top, open.top, shut.top, before.height, open.height, shut.height
            ))
        }
        window.orderOut(nil)
        return failed ? 1 : 0
    }

    private static func rowID(of cell: NSView, in column: ColumnView) -> String? {
        column.rowIDs.first { id in
            guard let place = column.onScreen(id) else { return false }
            let frame = cell.convert(cell.bounds, to: column.scrollView.contentView)
            return abs(frame.minY - column.scrollView.contentView.bounds.minY - place.top) < 0.5
        }
    }

    /// Through the application, as a real click arrives, so whatever watches
    /// the app's events sees it too.
    private static func click(_ point: NSPoint, in window: NSWindow) {
        for phase in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let event = NSEvent.mouseEvent(
                with: phase, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: phase == .leftMouseUp ? 0 : 1
            ) { NSApp.sendEvent(event) }
        }
    }

    private static func found<Kind: NSView>(in view: NSView) -> [Kind] {
        var kind: [Kind] = []
        if let match = view as? Kind { kind.append(match) }
        for child in view.subviews { kind += found(in: child) }
        return kind
    }

    private static func spin(_ times: Int) {
        for _ in 0..<times { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }
}
