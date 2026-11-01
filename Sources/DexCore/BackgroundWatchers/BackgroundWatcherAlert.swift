import Foundation

public enum BackgroundWatcherAlert {

    /// What a notification is filed under. The presenter opens the watcher list
    /// for anything filed under this prefix.
    public static let keyPrefix = "watcher:"

    public static func key(for watcher: BackgroundWatcher) -> String {
        keyPrefix + watcher.id
    }

    /// The one-line state a watcher is in, for the list and the notification.
    public static func headline(_ watcher: BackgroundWatcher, _ health: BackgroundWatcherHealth) -> String {
        switch health.condition {
        case .unreadable: return "status file can't be read"
        case .failed where health.isStale: return "failed, and hasn't run since"
        case .failed: return "last run failed"
        case _ where health.isStale: return "hasn't run when it should have"
        case .ok: return "started sessions"
        case .idle: return "nothing to do"
        case .neverRan: return "hasn't run yet"
        case .other(let raw): return raw
        }
    }

    public static func draft(
        _ watcher: BackgroundWatcher,
        _ health: BackgroundWatcherHealth,
        now: Date
    ) -> NotificationDraft? {
        guard health.needsAttention else { return nil }
        var body: [String] = []
        if case .unreadable(let reason) = health.condition {
            body.append(reason)
        }
        if let run = watcher.status?.lastRun {
            if case .failed = run.result {
                if let summary = run.summary { body.append(summary) }
                if let error = run.error { body.append(error) }
            }
            if health.isStale {
                body.append("Last ran \(Format.age(since: run.finishedAt, now: now)) ago.")
            }
        } else if health.isStale {
            body.append("It has never run.")
        }
        return NotificationDraft(
            title: "\(watcher.name): \(headline(watcher, health))",
            body: body.joined(separator: "\n"),
            key: key(for: watcher),
            sessionID: nil,
            needsInput: false
        )
    }
}
