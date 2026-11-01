import DexCore
import AppKit
import SwiftUI

/// The standing way into the composer, beside the project it would write to. It
/// draws over the window, so from the popover it brings the window with it, the
/// same as ⌘N does.
struct NewSessionButton: View {
    let store: SessionStore
    let layout: ListLayout

    @Environment(\.openWindow) private var openWindow
    @Environment(\.closePopover) private var closePopover

    private var flavor: AppFlavor { store.flavor }

    var body: some View {
        Button(action: open) {
            HStack(spacing: ChromeMetrics.iconGap) {
                Image(systemName: "plus.bubble")
                    .font(ChromeType.inlineIcon)
                Text("New \(flavor.noun)")
                    .font(ChromeType.body.weight(.medium))
            }
        }
        .buttonStyle(.bordered)
        // Until the first read lands there is no project to resolve, and the
        // composer would open on the home folder as though it were one. The row
        // this replaces was hidden for that window; a header button holds its
        // place and waits instead.
        .disabled(store.snapshot.hasNeverLoaded)
        .help(help)
    }

    private var help: String {
        // The shortcut is the window's, so the popover doesn't offer it.
        let shortcut = layout == .window ? " (⌘N)" : ""
        guard !store.snapshot.hasNeverLoaded else { return "New session\(shortcut)" }
        return "New session in \(Format.tildePath(store.composerTarget))\(shortcut)"
    }

    private func open() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow.open(flavor)
        store.openComposer()
        closePopover?()
    }
}
