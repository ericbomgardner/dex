import AppKit
import SwiftUI

/// Drag and double-click behaviour for the area a hidden titlebar leaves bare.
struct WindowChromeStrip: NSViewRepresentable {

    /// Whether the band has the conversation under it rather than padding. Over
    /// the list a click in it is the window's; over the pane it belongs to the
    /// transcript, and only the drag is the window's.
    var overContent = false

    func makeNSView(context: Context) -> NSView {
        overContent ? DragWatchView() : ChromeView()
    }

    func updateNSView(_ view: NSView, context: Context) {}

    /// Takes no event of its own — a click in the band reaches the transcript,
    /// and so does a scroll, a hover and a double-click on a word. What it picks
    /// out of the stream is the one thing underneath has no use for: a press in
    /// the band that goes on to move.
    private final class DragWatchView: NSView {

        private var monitor: Any?

        /// Whether the press this drag began with landed in the band.
        private var pressedInBand = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopWatching() } else { startWatching() }
        }

        private func startWatching() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { event in
                // The verdict comes back rather than the event: an NSEvent can't
                // be handed across an isolation boundary, and a Bool can.
                let taken = MainActor.assumeIsolated { [weak self] in
                    self?.takesAsDrag(event) ?? false
                }
                return taken ? nil : event
            }
        }

        private func stopWatching() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
            pressedInBand = false
        }

        /// True when the event was the window's to move by, and so is not the
        /// transcript's to see.
        private func takesAsDrag(_ event: NSEvent) -> Bool {
            guard let window, event.window === window else { return false }

            switch event.type {
            case .leftMouseDown:
                // Noted and passed on: a press that never moves is a click, and
                // the transcript has to have had it to answer for it.
                pressedInBand = bounds.contains(convert(event.locationInWindow, from: nil))
                return false

            // Cleared on the way up as well as on the way down. A press this
            // monitor never saw — one made while a menu owned the run loop, which
            // is a mode it is not watching — would otherwise be dragged by the
            // last one it did see, from wherever that was.
            case .leftMouseUp:
                pressedInBand = false
                return false

            case .leftMouseDragged:
                guard pressedInBand else { return false }
                pressedInBand = false

                // The event that is happening, not the press it began with: the
                // pointer has moved since then, and `performDrag` measures from
                // what it is handed — so a stale one starts by jumping the window
                // that far.
                window.performDrag(with: event)
                return true

            default:
                return false
            }
        }
    }

    private final class ChromeView: NSView {

        // Not mouseDownCanMoveWindow: letting AppKit drag the window swallows
        // the event and the double-click never arrives.
        override func mouseDown(with event: NSEvent) {
            guard let window else { return super.mouseDown(with: event) }

            if event.clickCount == 2 {
                Self.doubleClickAction().perform(on: window)
            } else {
                window.performDrag(with: event)
            }
        }

        /// "Double-click a window's title bar to" — absent means zoom.
        static func doubleClickAction() -> DoubleClickAction {
            let stored = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick")
            switch stored {
            case "Minimize": return .minimize
            case "None": return .none
            default: return .zoom
            }
        }
    }

    enum DoubleClickAction {
        case zoom
        case minimize
        case none

        @MainActor
        func perform(on window: NSWindow) {
            switch self {
            case .zoom: window.performZoom(nil)
            case .minimize: window.performMiniaturize(nil)
            case .none: break
            }
        }
    }
}
