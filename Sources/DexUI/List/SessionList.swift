import DexCore
import AppKit
import SwiftUI

struct SessionListView: View {
    @Bindable var store: SessionStore

    @State private var panel: NSWindow?

    private static let width: CGFloat = 440

    var body: some View {
        SessionListBody(store: store, layout: .popover)
            .frame(width: Self.width)
            .background(WindowAccessor { panel = $0 })
            .environment(\.closePopover) { panel?.close() }
    }
}

/// The `.window`-style `MenuBarExtra` has no presentation binding and its panel stays up when the window comes forward.
extension EnvironmentValues {
    @Entry var closePopover: (() -> Void)? = nil
}

enum ListLayout {

    case popover

    case window
}

struct SessionListBody: View {
    @Bindable var store: SessionStore
    let layout: ListLayout

    @Environment(\.openWindow) private var openWindow
    @Environment(\.closePopover) private var closePopover

    private var snapshot: Snapshot { store.snapshot }
    private var filtered: SessionFilter.Result { store.filtered }
    private var sections: SessionSections { store.sections }
    private var activeItems: [SessionListItem] { store.activeItems }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ListHeader(store: store, layout: layout)
            WatcherFilterBar(store: store)

            if let trouble = store.host.unavailable {
                DegradedBanner(reason: trouble, isStale: !snapshot.rows.isEmpty)
                Divider()
            }

            listArea

            if !sections.settled.isEmpty {
                Divider()
                SettledBar(store: store, layout: layout,
                           settled: sections.settled.count)
            }

            if store.isWaitingToReplaceHost {
                Divider()
                HostUpdateStrip()
            }

        }

        .onAppear { store.refresh() }
    }

    private var listArea: some View {
        ZStack(alignment: .bottom) {
            list

            if store.rebuilder.isRunning {
                WorkingToast(label: RebuildRunner.label, detail: store.rebuilder.progress)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if let outcome = store.toasts.lastOutcome {
                ActionOutcomeToast(outcome: outcome) { store.toasts.clear() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.18), value: store.toasts.lastOutcome)
        .animation(.snappy(duration: 0.18), value: store.rebuilder.isRunning)
    }

    @ViewBuilder
    private var list: some View {

        if filtered.visible.isEmpty, store.dispatches.pending.isEmpty {
            emptyState
        } else {
            switch layout {
            case .popover:
                MeasuredSessionList { listContent }
            case .window:
                ScrollViewReader { proxy in
                    ScrollView { listContent }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        .onChange(of: store.links.scrollTargetID) { _, rowID in
                            guard let rowID else { return }
                            withAnimation(.snappy(duration: 0.2)) { proxy.scrollTo(rowID) }
                        }
                }
            }
        }
    }

    private var showsSettledRows: Bool {
        layout == .window && store.showsSettled
    }

    private var listContent: some View {
        RowStack(isLazy: layout == .window) {

            let projectLabels = store.projectLabels

            if activeItems.isEmpty {
                allClearNotice
            } else {
                SessionRows(items: activeItems, store: store, openPane: openPane,
                            openStarting: openStarting, projectLabels: projectLabels,
                            isLazy: layout == .window)
            }

            if showsSettledRows, !sections.settled.isEmpty {
                Divider().opacity(0.4)

                SessionRows(items: sections.settled.map(SessionListItem.session), store: store,
                            openPane: openPane, openStarting: openStarting,
                            projectLabels: projectLabels, isLazy: true)
                    .opacity(0.55)
            }
        }
    }

    private var allClearNotice: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: "checkmark.circle")
                .font(ChromeType.inlineIcon)
                .foregroundStyle(ChromeColor.accent)
            Text("No unresolved sessions")
                .font(ChromeType.body)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.noticeVertical)
    }

    /// Picked from the popover, a row brings the window up to open in.
    private func openPane(_ row: SessionRowModel) {
        store.openPane(on: row)
        bringWindowForward()
    }

    /// A session that hasn't arrived holds the same pane a row's would.
    private func openStarting(_ pending: PendingDispatch) {
        store.pane.start(pending)
        bringWindowForward()
    }

    private func bringWindowForward() {
        NSApp.activate(ignoringOtherApps: true)
        openWindow.open(store.flavor)
        closePopover?()
    }

    private var emptyState: some View {

        Text(emptyMessage)
            .font(ChromeType.body)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity,
                   maxHeight: layout == .window ? .infinity : nil,
                   alignment: layout == .window ? .center : .leading)
            .padding(.horizontal, ChromeMetrics.listHorizontal)
            .padding(.vertical, ChromeMetrics.emptyVertical)
    }

    private var emptyMessage: String {
        if snapshot.hasNeverLoaded { return "Reading sessions…" }
        if let project = store.selectedProjectName {
            return "No sessions in \(project) yet."
        }
        return "No sessions."
    }
}

struct MeasuredSessionList<Content: View>: View {
    @ViewBuilder let content: Content

    private static var maxVisibleHeight: CGFloat { 440 }

    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                    }
                )
        }
        .onPreferenceChange(ContentHeightKey.self) { height in
            contentHeight = height
        }
        .frame(height: min(max(contentHeight, 1), Self.maxVisibleHeight))
    }
}

struct SettledBar: View {
    @Bindable var store: SessionStore
    let layout: ListLayout
    let settled: Int

    @Environment(\.openWindow) private var openWindow
    @Environment(\.closePopover) private var closePopover

    private var isShowing: Bool { layout == .window && store.showsSettled }

    var body: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: "checkmark.circle.fill")
                .font(ChromeType.inlineIcon)
                .foregroundStyle(.tertiary)
            Text("\(settled) recently resolved")
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
            Spacer()
            Button(isShowing ? "Hide" : "Show") { toggle() }
                .buttonStyle(AccentLinkStyle())
                .font(ChromeType.meta)
                .help(help)
        }
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.barVertical)
    }

    private var help: String {
        switch layout {
        case .popover: "Show resolved sessions in the window"
        case .window: store.showsSettled ? "Hide resolved sessions" : "Show resolved sessions"
        }
    }

    private func toggle() {
        switch layout {
        case .popover:
            store.showsSettled = true
            NSApp.activate(ignoringOtherApps: true)
            openWindow.open(store.flavor)
            closePopover?()
        case .window:
            withAnimation(.snappy(duration: 0.18)) { store.showsSettled.toggle() }
        }
    }
}

/// Shown only while a host from an older build is kept for the sessions it is
/// running; it is replaced, as at open, once they finish.
struct HostUpdateStrip: View {
    var body: some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(ChromeType.inlineIcon)
                .foregroundStyle(.tertiary)
            Text("Updating the host once sessions finish")
                .font(ChromeType.meta)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.barVertical)
        .help("The host is from an older build of Dex. It is replaced once nothing is running on it, and idle sessions come back on their next message.")
    }
}

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct DegradedBanner: View {
    var title = "The host isn't running"
    let reason: String
    let isStale: Bool
    var dismiss: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: ChromeMetrics.iconGap) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(ChromeType.inlineIcon)
            VStack(alignment: .leading, spacing: ChromeMetrics.lineGap) {
                Text(title)
                    .font(ChromeType.body.weight(.semibold))
                Text(reason)
                    .font(ChromeType.meta)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isStale {
                    Text("Showing the last list that loaded — it may be out of date.")
                        .font(ChromeType.meta)
                        .foregroundStyle(.secondary)
                }
            }
            if let dismiss {
                Spacer(minLength: ChromeMetrics.iconGap)
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(ChromeType.inlineIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
                .help("Hide until it connects again")
            }
        }
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.headerVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08))
    }
}
