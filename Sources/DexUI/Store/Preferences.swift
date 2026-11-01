import DexCore
import Foundation
import Observation

/// The app-wide settings, each written to `Defaults` as it changes. The ones
/// with consequences beyond the write say so through the store's hooks.
@MainActor
@Observable
final class Preferences {
    var windowWasOpen: Bool {
        didSet { Defaults.sessionsWindowWasOpen = windowWasOpen }
    }

    /// Whether the window was up when the app last quit, read once at launch.
    let shouldRestoreWindow: Bool

    /// How every session started here writes. One app-wide pick in Settings
    /// rather than a dial in the composer, which since CLI v2.1.278 is a choice
    /// and not a limit: `applyFlagSettings` will move a running session's style
    /// from the next turn, where it used to accept one and change nothing.
    /// Deferred until a row's own voice is worth the control.
    var outputStyle: OutputStyle {
        didSet { Defaults.outputStyle = outputStyle }
    }

    /// The styles to offer, kept across launches. The CLI is the only source and
    /// it answers only while a session runs, so what the host says replaces this
    /// and nothing empties it.
    var knownOutputStyles: [String] {
        didSet { Defaults.knownOutputStyles = knownOutputStyles }
    }

    var postsNotifications: Bool {
        didSet {
            Defaults.postsNotifications = postsNotifications
            if postsNotifications { onNotificationsOn?() }
        }
    }

    /// Whether the Mac is held awake while any hosted session is working.
    var keepsAwake: Bool {
        didSet {
            Defaults.keepsAwake = keepsAwake
            onKeepsAwake?(keepsAwake)
        }
    }

    @ObservationIgnored var onNotificationsOn: (() -> Void)?
    @ObservationIgnored var onKeepsAwake: ((Bool) -> Void)?

    init() {
        let wasOpen = Defaults.sessionsWindowWasOpen
        self.windowWasOpen = wasOpen
        self.shouldRestoreWindow = wasOpen
        self.outputStyle = Defaults.outputStyle
        self.knownOutputStyles = Defaults.knownOutputStyles
        self.postsNotifications = Defaults.postsNotifications
        self.keepsAwake = Defaults.keepsAwake
    }
}
