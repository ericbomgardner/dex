import DexCore
import AppKit
import SwiftUI

struct ListHeader: View {
    @Bindable var store: SessionStore
    let layout: ListLayout

    @Environment(\.openWindow) private var openWindow
    @Environment(\.closePopover) private var closePopover

    var body: some View {
        HStack(spacing: ChromeMetrics.controlGap) {
            ProjectPicker(store: store, labelFont: .headline)
            // Only where the folder is one this Mac has: a path that isn't
            // here either misses or lands on a stranger of the same name.
            if let project = store.selectedProject, store.isLocalFolder(project) {
                OpenFolderButton(path: project)
            }
            Spacer(minLength: 0)
            attentionNotice
            if
                !store.watchers.watchers.isEmpty
            {
                WatchersChip(store: store, layout: layout)
            }
            NewSessionButton(store: store, layout: layout)
            buildChip
            // The window reaches Settings and Quit through the app menu; the
            // popover has no menu bar of its own, so it keeps the gear.
            if layout == .popover {
                SettingsMenu(store: store)
                openInWindow
            }
        }
        .padding(.horizontal, ChromeMetrics.listHorizontal)
        .padding(.vertical, ChromeMetrics.headerVertical)
    }

    @ViewBuilder
    private var attentionNotice: some View {

        if let elsewhere = blockedElsewhereNotice {
            Button { store.selectedProject = nil } label: {
                waitingLabel(elsewhere)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.orange)
            .help("Show every project")
        } else if store.waitingCount > 0 {
            waitingLabel("\(store.waitingCount) waiting on you")
                .foregroundStyle(.orange)
        }
    }

    private func waitingLabel(_ text: String) -> some View {
        HStack(spacing: ChromeMetrics.iconGap) {
            Image(systemName: "person.wave.2.fill")
                .font(ChromeType.inlineIcon)
            Text(text)
                .font(ChromeType.meta)
                .lineLimit(1)
        }
    }

    private var blockedElsewhereNotice: String? {
        let count = store.filtered.blockedElsewhere
        guard count > 0 else { return nil }
        return count == 1 ? "1 waiting elsewhere" : "\(count) waiting elsewhere"
    }

    @ViewBuilder
    private var buildChip: some View {
        if let checkout = store.rebuilder.checkout, checkout.isWorktree {
            BuildChip(checkout: checkout, build: store.rebuilder.runningBuild)
        }
    }

    private var openInWindow: some View {
        Button {
            NSApp.activate(ignoringOtherApps: true)
            openWindow.open(store.flavor)
            closePopover?()
        } label: {
            Image(systemName: "macwindow")
                .font(ChromeType.control)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Open window")
    }
}

extension View {
    /// A borderless menu draws its title in the window's tint, and a menu here
    /// is a readout of what is chosen, not a link.
    func untinted() -> some View { tint(nil) }
}

/// A text button in the app's accent; `.link` ignores the tint for the
/// system's link blue.
struct AccentLinkStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(ChromeColor.accent)
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/// Which checkout this copy came out of. Only a worktree build says so: several
/// can be running at once, and in the menu bar they are identical to each other
/// and to the copy kept open all day.
struct BuildChip: View {
    let checkout: AppCheckout
    let build: RunningBuild?

    var body: some View {
        HStack(spacing: ChromeMetrics.badgeGap) {
            Image(systemName: "hammer.fill")
                .font(ChromeType.badgeIcon)
                .foregroundStyle(.tertiary)

            Text(checkout.name)
                .font(ChromeType.badge)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: ChromeMetrics.chipNameSlot, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, ChromeMetrics.badgeHorizontal)
        .padding(.vertical, ChromeMetrics.badgeVertical)
        .background(Capsule().fill(Color.primary.opacity(ChromeMetrics.chipTint)))
        .help(tooltip)
    }

    private var tooltip: String {
        var line = "This copy was built from \(Format.tildePath(checkout.root))"
        if let build { line += ", at \(build.commit.prefix(7))" }
        return line
    }
}

struct SettingsMenu: View {
    @Bindable var store: SessionStore

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Menu {
            Button("Settings…") {
                NSApp.activate(ignoringOtherApps: true)
                openSettings()
            }

            Section {
                Button(quitLabel) { NSApp.terminate(nil) }
            }
        } label: {
            Image(systemName: "gearshape")
                .font(ChromeType.control)
        }
        .menuStyle(.borderlessButton)
        .untinted()
        .menuIndicator(.hidden)
        .frame(width: ChromeMetrics.settingsSlot)
        .help("Settings")
    }

    private var quitLabel: String {
        guard let checkout = store.rebuilder.checkout, checkout.isWorktree else { return "Quit" }
        return "Quit This Build (\(checkout.name))"
    }
}
