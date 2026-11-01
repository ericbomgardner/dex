import DexCore
import Foundation
import os

/// Everything the app remembers between launches. A mistyped key reads as
/// "nothing saved" rather than failing, so they all live here.
enum Defaults {
    static var store: UserDefaults { .standard }

    static var selectedProject: String? {
        get { store.string(forKey: "selectedProject") }
        set { store.set(newValue, forKey: "selectedProject") }
    }

    static var composerDirectory: String? {
        get { store.string(forKey: "composerDirectory") }
        set { store.set(newValue, forKey: "composerDirectory") }
    }

    static var recentFolders: RecentFolders {
        get { decoded(RecentFolders.self, "recentFolders") ?? RecentFolders() }
        set { encode(newValue, "recentFolders") }
    }

    static var composerDraft: String {
        get { ComposerDraft.restored(store.string(forKey: "composerDraft")) }
        set { store.set(ComposerDraft.persistable(newValue), forKey: "composerDraft") }
    }

    static var composerAttachments: [ComposerAttachment] {
        get {
            ComposerAttachments.present(
                (store.stringArray(forKey: "composerAttachments") ?? []).map(ComposerAttachment.init)
            )
        }
        set { store.set(newValue.isEmpty ? nil : newValue.map(\.path), forKey: "composerAttachments") }
    }

    /// One setting, not one per project.
    static var composerModel: SessionModel {
        get { SessionModel(stored: store.string(forKey: "composerModel")) }
        set { store.set(newValue.stored, forKey: "composerModel") }
    }

    static var composerEffort: EffortLevel {
        get { EffortLevel(stored: store.string(forKey: "composerEffort")) }
        set { store.set(newValue.stored, forKey: "composerEffort") }
    }

    /// How every session this app starts writes. One setting rather than one
    /// per session because the app binds a style at launch and offers no dial —
    /// the SDK would move one on a running session since CLI v2.1.278, but
    /// nothing here has asked for per-row voices — so it lives in Settings,
    /// beside the notification toggle, rather than in the composer beside the
    /// pickers that can be changed later.
    static var outputStyle: OutputStyle {
        get { OutputStyle(stored: store.string(forKey: "outputStyle")) }
        set { store.set(newValue.stored, forKey: "outputStyle") }
    }

    /// The styles the CLI last said it had. Kept because the only place that
    /// list exists is a running session's `initializationResult()`: without
    /// this, the picker in Settings has one row until you have started a session
    /// under the host you are connected to.
    static var knownOutputStyles: [String] {
        get { store.stringArray(forKey: "knownOutputStyles") ?? [] }
        set { store.set(newValue.isEmpty ? nil : newValue, forKey: "knownOutputStyles") }
    }

    /// Still under the terminal-era key, so drafts survived that upgrade.
    static var paneDrafts: ComposerDrafts {
        get { (decoded(ComposerDrafts.self, "terminalDrafts") ?? ComposerDrafts()).present() }
        set { encode(newValue, "terminalDrafts") }
    }

    /// Open until you close it: a fresh install of the app has only the menu
    /// bar item otherwise, and nothing says the window exists.
    static var sessionsWindowWasOpen: Bool {
        get { store.object(forKey: "sessionsWindowOpen") as? Bool ?? true }
        set { store.set(newValue, forKey: "sessionsWindowOpen") }
    }

    /// On unless you turn it off.
    static var postsNotifications: Bool {
        get { store.object(forKey: "postsNotifications") as? Bool ?? true }
        set { store.set(newValue, forKey: "postsNotifications") }
    }

    /// On unless you turn it off: a laptop that sleeps under a working session
    /// loses the turn, and nothing in the app would say so.
    static var keepsAwake: Bool {
        get { store.object(forKey: "keepsAwake") as? Bool ?? true }
        set { store.set(newValue, forKey: "keepsAwake") }
    }

    static var resolutions: SessionResolutions {
        get { decoded(SessionResolutions.self, "sessionResolutions") ?? SessionResolutions() }
        set { encode(newValue, "sessionResolutions") }
    }

    /// Each background watcher's last-announced problem, by file name, so a
    /// relaunch doesn't announce it again.
    static var watcherAlerts: [String: String] {
        get { store.dictionary(forKey: "watcherAlerts") as? [String: String] ?? [:] }
        set { store.set(newValue.isEmpty ? nil : newValue, forKey: "watcherAlerts") }
    }

    static var hostedArchive: HostedArchive {
        get { decoded(HostedArchive.self, "hostedArchive") ?? HostedArchive() }
        set { encode(newValue, "hostedArchive") }
    }

    private static let logger = Logger(subsystem: BundleIdentity.code, category: "defaults")

    /// Where a value that would not decode is kept, so the next write over its
    /// key doesn't lose it. Every distinct one, oldest first.
    static func unreadableKey(_ key: String) -> String { key + ".unreadable" }

    static func decoded<T: Decodable>(_ type: T.Type, _ key: String, in store: UserDefaults = store) -> T? {
        guard let data = store.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            logger.error("\(key, privacy: .public) would not decode, kept under \(unreadableKey(key), privacy: .public): \(String(describing: error), privacy: .public)")
            var kept = store.array(forKey: unreadableKey(key)) as? [Data] ?? []
            if !kept.contains(data) {
                kept.append(data)
                store.set(kept, forKey: unreadableKey(key))
            }
            return nil
        }
    }

    static func encode(_ value: some Encodable, _ key: String, in store: UserDefaults = store) {
        do {
            store.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            logger.error("\(key, privacy: .public) would not encode, left as it was: \(String(describing: error), privacy: .public)")
        }
    }
}
