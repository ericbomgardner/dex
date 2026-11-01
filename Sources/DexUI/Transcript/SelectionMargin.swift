import AppKit
import SwiftUI

/// The pane behind the column, so a drag can start in the space beside a line
/// rather than on it.
///
/// Selecting whole lines otherwise means landing the mouse exactly on the first
/// character, and a reply is read in a column with a hand's width of nothing
/// either side of it. The point is resolved the same way the far end of any
/// drag is — against the nearest piece — so starting off the left of a line
/// starts at the beginning of it, and off the right ends at the end.
struct SelectionMargin: NSViewRepresentable {

    @Environment(\.transcriptSelection) private var selection

    func makeNSView(context: Context) -> MarginView {
        let view = MarginView()
        view.hold(selection)
        return view
    }

    func updateNSView(_ view: MarginView, context: Context) {
        view.hold(selection)
    }

    /// Whatever it is put behind. There is nothing here with a size of its own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: MarginView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

package final class MarginView: SelectionSurface {

    package override func mouseDown(with event: NSEvent) {
        // Said rather than left to AppKit, which promotes a clicked view that
        // accepts the caret on its own — the same reason the runs of prose say
        // it. Whichever surface the selection was started in is the one ⌘C is
        // offered to.
        window?.makeFirstResponder(self)
        owner?.press(atWindow: event.locationInWindow,
                     extending: event.modifierFlags.contains(.shift))
    }

    package override func mouseDragged(with event: NSEvent) {
        owner?.drag(toWindow: event.locationInWindow)
        autoscroll(with: event)
    }
}
