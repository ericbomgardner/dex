import AppKit
import SwiftUI

/// Two columns with a draggable divider.
///
/// Not `HSplitView`, which ties the starting width to the drag ceiling, nor
/// `NavigationSplitView`, which adds a sidebar toggle to the titlebar this
/// window hides.
struct SplitColumns<Sidebar: View, Detail: View>: NSViewControllerRepresentable {

    let initialSidebarWidth: CGFloat
    let minimumSidebarWidth: CGFloat
    let minimumDetailWidth: CGFloat
    let autosaveName: String

    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let detail: Detail

    func makeNSViewController(context: Context) -> NSSplitViewController {
        let controller = NSSplitViewController()
        controller.splitView.dividerStyle = .thin
        controller.splitView.autosaveName = autosaveName

        let side = NSSplitViewItem(viewController: Self.column(sidebar, scheme: context.environment.colorScheme))
        side.minimumThickness = minimumSidebarWidth
        side.canCollapse = false

        // Higher than the detail column's, so window resizing goes there and
        // the sidebar keeps the width you gave it.
        side.holdingPriority = .init(NSLayoutConstraint.Priority.defaultLow.rawValue + 1)
        controller.addSplitViewItem(side)

        let main = NSSplitViewItem(viewController: Self.column(detail, scheme: context.environment.colorScheme))
        main.minimumThickness = minimumDetailWidth
        controller.addSplitViewItem(main)

        if !Self.hasSavedPosition(autosaveName) {
            let width = initialSidebarWidth
            DispatchQueue.main.async {
                controller.splitView.setPosition(width, ofDividerAt: 0)
            }
        }
        return controller
    }

    func updateNSViewController(_ controller: NSSplitViewController, context: Context) {
        let items = controller.splitViewItems
        guard items.count == 2 else { return }

        let scheme = context.environment.colorScheme
        (items[0].viewController as? NSHostingController<Column<Sidebar>>)?
            .rootView = Column(content: sidebar, scheme: scheme)
        (items[1].viewController as? NSHostingController<Column<Detail>>)?
            .rootView = Column(content: detail, scheme: scheme)

        if items[0].minimumThickness != minimumSidebarWidth {
            items[0].minimumThickness = minimumSidebarWidth
        }
        if items[1].minimumThickness != minimumDetailWidth {
            items[1].minimumThickness = minimumDetailWidth
        }
    }

    /// Declines to offer a size. Left to its default the controller offers its
    /// content's height, the split takes it, and a short list drags the whole
    /// split down to the foot of the window.
    private static func column<C: View>(_ content: C, scheme: ColorScheme) -> NSHostingController<Column<C>> {
        let controller = NSHostingController(rootView: Column(content: content, scheme: scheme))
        controller.sizingOptions = []
        return controller
    }

    private static func hasSavedPosition(_ name: String) -> Bool {
        UserDefaults.standard.object(forKey: "NSSplitView Subview Frames \(name)") != nil
    }

    /// Named so `updateNSViewController` has a type to cast back to.
    struct Column<C: View>: View {
        let content: C
        /// Handed down rather than inherited: a column left to follow the window
        /// went dark with it and stayed dark when the window came back.
        let scheme: ColorScheme

        var body: some View {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .environment(\.colorScheme, scheme)
        }
    }
}
