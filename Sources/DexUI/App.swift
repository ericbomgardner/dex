import DexCore
import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SessionStore(flavor: Entry.flavor)

    private var flavor: AppFlavor { store.flavor }

    private var isTerminating = false

    /// An Apple event handler rather than `application(_:open:)`, which SwiftUI
    /// answers first by opening a window. Installed before launch finishes so
    /// the link that launched the app is caught too.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:reply:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string),
              let link = SessionLink(url: url, scheme: flavor.linkScheme)
        else { return }
        store.open(link)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        observeWindowClosing()
        // Not syncWindowState: the window hasn't opened yet, and it would record that.
        syncActivationPolicy()

        store.prepareNotifications()
        store.start()
    }

    /// Closing the window leaves the app running, so the next `open` — or Dock
    /// click — finds it running and has only this to arrive as.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        store.showWindow()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        store.stop()
    }

    func syncWindowStateSoon() {
        Task { @MainActor in self.syncWindowState() }
    }

    private func observeWindowClosing() {
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncWindowStateSoon() }
        }
    }

    private func syncWindowState() {
        guard !isTerminating else { return }

        store.preferences.windowWasOpen = SessionsWindow.isOpen(flavor)
        syncActivationPolicy()
    }

    private func syncActivationPolicy() {
        let policy: NSApplication.ActivationPolicy =
            NSApp.windows.contains(where: isRealWindow) ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        if policy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func isRealWindow(_ window: NSWindow) -> Bool {
        guard window.isVisible else { return false }
        if SessionsWindow.isSessionsWindow(window, flavor) { return true }

        return window.canBecomeMain && !(window is NSPanel)
    }
}

/// A menu bar item, and a window the app drops out of the Dock without.
struct CodeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            SessionListView(store: delegate.store)
                .tint(ChromeColor.accent)
        } label: {
            MenuBarLabel(snapshot: delegate.store.snapshot,
                         waiting: delegate.store.waitingCount,
                         hostTrouble: delegate.store.host.unavailable != nil,
                         isRebuilding: delegate.store.rebuilder.isRunning)

                .modifier(RestoreSessionsWindow(store: delegate.store))

                .modifier(FocusWindowBridge(store: delegate.store))
        }
        .menuBarExtraStyle(.window)

        Window(delegate.store.flavor.title, id: delegate.store.flavor.windowID) {
            SessionsWindowView(store: delegate.store) {
                delegate.syncWindowStateSoon()
            }
            .tint(ChromeColor.accent)
        }
        .defaultSize(width: SessionsWindow.defaultWidth, height: SessionsWindow.defaultHeight)
        .windowStyle(.hiddenTitleBar)
        .commands { AppCommands(store: delegate.store) }

        Settings {
            SettingsView(store: delegate.store)
                .tint(ChromeColor.accent)
        }
    }
}

struct AppCommands: Commands {
    let store: SessionStore

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            NewSessionCommand(store: store)
            Divider()
            ResolveAllCommand(store: store)
        }

        CommandMenu("Go") {
            QuickSwitchCommands(store: store)
            Divider()
            ShowWindowCommand(store: store)
        }

        // Off a checkout there is nothing to rebuild.
        if store.rebuilder.checkout != nil {
            CommandMenu("Debug") {
                DebugCommands(store: store)
            }
        }
    }
}

extension OpenWindowAction {
    func open(_ flavor: AppFlavor) {
        self(id: flavor.windowID)
    }
}

/// Unlike the palette, this one doesn't wait for the window to be key — it brings
/// the window with it, since asking to write is a poor time to be told no.
private struct NewSessionCommand: View {
    let store: SessionStore

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New \(store.flavor.capitalizedNoun)…") {
            NSApp.activate(ignoringOtherApps: true)
            openWindow.open(store.flavor)
            store.openComposer()
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

private struct ShowWindowCommand: View {
    let store: SessionStore

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(store.flavor.windowCommand) {
            NSApp.activate(ignoringOtherApps: true)
            openWindow.open(store.flavor)
        }
    }
}

/// The sweep the header used to carry. It reaches the same rows the popover
/// draws, so unlike the palette's commands it doesn't wait for the window.
private struct ResolveAllCommand: View {
    let store: SessionStore

    var body: some View {
        let resolvable = store.resolvableNow.count

        Button("Mark All as Resolved") { store.resolveAllVisible() }
            .disabled(resolvable == 0)
            .keyboardShortcut("r", modifiers: [.command, .shift])
    }
}

private struct DebugCommands: View {
    let store: SessionStore

    var body: some View {
        let rebuilding = store.rebuilder.isRunning

        // The host is replaced on the new app's start if nothing is running on it.
        Button(rebuilding ? "Rebuilding…" : "Rebuild and Restart") {
            store.rebuilder.rebuildAndRestart()
        }
        .disabled(rebuilding)
    }
}

/// The palette draws inside the sessions window, so the shortcuts stay quiet
/// while the menu bar popover is the one taking keys.
private struct QuickSwitchCommands: View {
    let store: SessionStore

    var body: some View {
        Button("Switch Project or Session…") { open(.everything) }
            .keyboardShortcut("k", modifiers: .command)

        Button("Switch Project…") { open(.projectsOnly) }
            .keyboardShortcut("o", modifiers: [.command, .shift])

        Button(Branding.findCommand) {
            guard SessionsWindow.isKey(store.flavor) else { return }
            store.openSearch()
        }
        .keyboardShortcut("f", modifiers: [.command, .shift])
    }

    private func open(_ scope: QuickSwitchScope) {
        guard SessionsWindow.isKey(store.flavor) else { return }
        store.openQuickSwitch(scope)
    }
}

private struct FocusWindowBridge: ViewModifier {
    let store: SessionStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onChange(of: store.links.focusRequest) { _, request in
            guard let request else { return }
            NSApp.activate(ignoringOtherApps: true)
            openWindow.open(store.flavor)
            store.links.clearFocusRequest()
        }
    }
}

private struct RestoreSessionsWindow: ViewModifier {
    let store: SessionStore
    @Environment(\.openWindow) private var openWindow
    @State private var hasRun = false

    func body(content: Content) -> some View {
        content.task {
            guard !hasRun else { return }
            hasRun = true
            if store.preferences.shouldRestoreWindow { openWindow.open(store.flavor) }
        }
    }
}
