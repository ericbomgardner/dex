import AppKit
import SwiftUI

extension View {
    /// The pane's ground.
    func paneGround(_ usual: NSColor) -> some View {
        modifier(PaneGround(usual: usual))
    }
}

private struct PaneGround: ViewModifier {
    let usual: NSColor

    func body(content: Content) -> some View {
        content.background(ground)
    }

    private var ground: Color {
        return Color(nsColor: usual)
    }
}

extension NSView {
    /// A window can be handed a scheme of its own through SwiftUI, since its
    /// appearance set back to nil left SwiftUI drawing dark; AppKit text inside
    /// it has to be told the same.
    func follow(_ scheme: ColorScheme) {
        let name: NSAppearance.Name = scheme == .dark ? .darkAqua : .aqua
        if appearance?.name != name { appearance = NSAppearance(named: name) }
    }
}
