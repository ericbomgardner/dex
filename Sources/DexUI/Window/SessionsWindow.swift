import DexCore
import AppKit
import SwiftUI

/// The app's one window. Its scene id is what SwiftUI remembers a frame by.
enum SessionsWindow {
    /// Off its scene id: false for the popover, Settings, and anything else
    /// AppKit has up.
    @MainActor
    static func isSessionsWindow(_ window: NSWindow, _ flavor: AppFlavor) -> Bool {
        window.identifier?.rawValue == flavor.windowID
    }

    @MainActor
    static func isOpen(_ flavor: AppFlavor) -> Bool {
        NSApp.windows.contains { $0.isVisible && isSessionsWindow($0, flavor) }
    }

    /// Whether it is taking keys, which the menu bar popover is when it is
    /// open — the shortcuts drawn into the window belong to it alone.
    @MainActor
    static func isKey(_ flavor: AppFlavor) -> Bool {
        NSApp.windows.contains { $0.isKeyWindow && isSessionsWindow($0, flavor) }
    }

    static let listInitialWidth: CGFloat = 460
    static let listMinWidth: CGFloat = 340
    static let detailInitialWidth: CGFloat = 620

    /// Both columns from the first open. Sized to the list alone, the detail
    /// column opened at zero and the window read as a list with nothing beside it.
    static let defaultWidth: CGFloat = listInitialWidth + detailInitialWidth
    static let defaultHeight: CGFloat = 720
    static let minWidth: CGFloat = 360
    static let minHeight: CGFloat = 320

    /// The strip the traffic lights sit in: the frame AppKit would wrap around
    /// an empty content rect.
    @MainActor
    static let titlebarHeight: CGFloat = NSWindow.frameRect(
        forContentRect: .zero,
        styleMask: [.titled, .closable, .miniaturizable, .resizable]
    ).height
}

struct SessionsWindowView: View {
    @Bindable var store: SessionStore

    let windowPresenceChanged: () -> Void

    @State private var isDropTarget = false

    @Environment(\.colorScheme) private var systemScheme

    private var pane: SessionPane { store.pane }

    /// Whether the takeover bars are up. While they are, the titlebar band is
    /// theirs — above them, across the whole window — and the columns start
    /// flush under them rather than keeping clear of a band that is no longer
    /// at their top.
    private var barsUp: Bool {
        return !store.takeovers.list.isEmpty
    }


    var body: some View {
        return VStack(spacing: 0) {
            if barsUp { takeoverBars }

            // A hidden titlebar still reports its height as safe area, and a
            // split view re-establishes it for the views it arranges — so each
            // column has to decline it as well, or both sit below the titlebar.
            SplitColumns(
                initialSidebarWidth: SessionsWindow.listInitialWidth,
                minimumSidebarWidth: SessionsWindow.listMinWidth,
                minimumDetailWidth: detailMinWidth,
                autosaveName: store.flavor.columnsAutosaveName
            ) {
                listColumn
                    .ignoresSafeArea(.container, edges: .top)
            } detail: {
                detailColumn
                    .ignoresSafeArea(.container, edges: .top)
            }
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: minWindowWidth, minHeight: SessionsWindow.minHeight)
        .animation(.easeOut(duration: 0.12), value: store.takeovers.list)
        .overlay {
            switch store.overlay {
            case .quickSwitch(let scope):
                QuickSwitchOverlay(store: store, scope: scope)
                    .id(scope)
            case .composer:
                ComposerOverlay(store: store)
            case .search:
                SearchOverlay(store: store)
            case nil:
                EmptyView()
            }
        }
        .animation(.easeOut(duration: 0.12), value: store.overlay)
        .background(WindowAccessor { window in
            let title = store.flavor.title
            if window.title != title { window.title = title }
            growForPane(window)
        })

        .onAppear { windowPresenceChanged() }
        .onDisappear {
            windowPresenceChanged()

            pane.close()
        }
    }

    /// Across the whole window and in the layout, under the traffic lights:
    /// whichever row is open, the machine being driven is the same one, and
    /// both columns move down by the bars' height rather than sit under them.
    /// They were laid over the columns once, and covered the open row's title
    /// and the top of its transcript for as long as the session had the screen.

    private var takeoverBars: some View {
        VStack(spacing: 0) {
            WindowChromeStrip()
                .frame(height: SessionsWindow.titlebarHeight)


            ForEach(store.takeovers.list, id: \.key) { takeover in
                ScreenTakeoverBar(
                    name: store.takeovers.name(of: takeover),
                    takeover: takeover,
                    stop: { store.takeovers.stop(takeover) }
                )
            }
        }
    }

    /// The transcript runs up under the traffic-light strip rather than keeping
    /// clear of it the way the list does, so the band is bare. The strip is laid
    /// over it all the same: without one, the window cannot be moved by its
    /// right-hand half at all.
    private var detailColumn: some View {
        HStack(spacing: 0) {
            paneColumn
                .overlay(alignment: .top) {
                    if !barsUp {
                        WindowChromeStrip(overContent: true)
                            .frame(height: SessionsWindow.titlebarHeight)
                    }
                }
        }
    }

    @ViewBuilder
    private var paneColumn: some View {
        if let starting = pane.starting {
            StartingPane(pending: starting)
        } else if let attachment = pane.attachment {
            SessionPaneView(store: store, pane: pane, attachment: attachment)
        } else {
            EmptyDetailColumn(noun: store.flavor.noun)
        }
    }

    private var listColumn: some View {
        SessionListBody(store: store, layout: .window)
            // The whole column takes a drag: a drop is easier to aim at a list
            // than at a field, and it lands in the composer where there is room
            // to say what to do with it.
            .overlay { if isDropTarget { dropInvitation } }
            .overlay(ComposerDropCatcher(isTargeted: $isDropTarget) {
                store.attachAndCompose($0)
            })
            .animation(.easeOut(duration: 0.12), value: isDropTarget)
            .padding(.top, barsUp ? 0 : SessionsWindow.titlebarHeight)
            .overlay(alignment: .top) {
                if !barsUp {
                    WindowChromeStrip()
                        .frame(height: SessionsWindow.titlebarHeight)
                }
            }
    }

    private var dropInvitation: some View {
        ZStack {
            DropHighlight(corner: ChromeMetrics.fieldCorner)

            VStack(spacing: ChromeMetrics.inlineGap) {
                Image(systemName: "paperclip")
                    .font(ChromeType.displayGlyph)
                Text("Drop to attach")
                    .font(ChromeType.title.weight(.medium))
            }
            .foregroundStyle(ChromeColor.accent)
        }
        .allowsHitTesting(false)
    }

    private var detailMinWidth: CGFloat {
        var width = pane.isOpen ? SessionPaneView.minWidth : 0
        return width
    }

    private var minWindowWidth: CGFloat {
        var width = pane.isOpen
            ? SessionsWindow.listMinWidth + SessionPaneView.minWidth
            : SessionsWindow.minWidth
        return width
    }

    private func growForPane(_ window: NSWindow) {
        var grows = pane.isOpen
        guard grows else { return }
        let wanted = minWindowWidth
        guard window.frame.width < wanted else { return }

        var frame = window.frame
        frame.size.width = wanted

        if let visible = window.screen?.visibleFrame {
            if frame.maxX > visible.maxX {
                frame.origin.x = max(visible.minX, visible.maxX - frame.width)
            }
        }
        window.setFrame(frame, display: true, animate: true)
    }
}

struct EmptyDetailColumn: View {
    var noun = "session"

    private static let minContentWidth: CGFloat = 220

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear.paneGround(.textBackgroundColor)
                if proxy.size.width >= Self.minContentWidth {
                    placeholder
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        VStack(spacing: ChromeMetrics.inlineGap) {
            Image(systemName: "text.bubble")
                .font(ChromeType.displayGlyph)
                .foregroundStyle(.quaternary)
            Text("No \(noun) open")
                .font(ChromeType.title.weight(.medium))
                .foregroundStyle(.secondary)

            Text("Click a \(noun) to open it here")
                .font(ChromeType.body)
                .foregroundStyle(.tertiary)
        }
        .multilineTextAlignment(.center)

        .padding(.horizontal, 16)
    }
}

struct ColumnHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        apply(from: view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(from: view)
    }

    private func apply(from view: NSView) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            configure(window)
        }
    }
}
