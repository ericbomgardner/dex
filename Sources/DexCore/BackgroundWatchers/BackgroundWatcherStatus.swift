import Foundation

/// One `~/.claude/dex/watchers/<name>.json`: a launchd job that starts sessions
/// through the host socket, saying how its last run went. Dex knows only the
/// directory and this schema, never a particular watcher.
///
/// Read leniently. A field that won't decode is left nil rather than failing
/// the file, because a watcher that drops out of the list is the one failure
/// nobody would notice.
public struct BackgroundWatcherStatus: Hashable, Sendable {

    public static let knownVersion = 1

    public var version: Int
    public var name: String
    public var description: String?
    public var launchdLabel: String?
    public var schedule: Schedule?
    public var logPath: String?
    /// Nil before the first real run: an install can write the file early so
    /// the watcher shows up as never having run.
    public var lastRun: Run?
    public var lastSuccessAt: Date?
    /// Newest first.
    public var sessions: [StartedSession]

    public enum Schedule: Hashable, Sendable {
        case every(TimeInterval)
        case daily(hour: Int, minute: Int)
    }

    public enum Result: Hashable, Sendable {
        case ok, idle, failed
        case other(String)

        init(_ raw: String) {
            switch raw {
            case "ok": self = .ok
            case "idle": self = .idle
            case "failed": self = .failed
            default: self = .other(raw)
            }
        }

        public var raw: String {
            switch self {
            case .ok: "ok"
            case .idle: "idle"
            case .failed: "failed"
            case .other(let raw): raw
            }
        }
    }

    public struct Run: Hashable, Sendable {
        public var startedAt: Date?
        public var finishedAt: Date
        public var result: Result
        public var summary: String?
        public var error: String?
    }

    public struct StartedSession: Hashable, Sendable {
        public var key: String
        public var name: String?
        public var startedAt: Date?
        public var reason: String?
        public var url: String?
    }

    public var expandedLogPath: String? {
        guard let logPath, !logPath.isEmpty else { return nil }
        return (logPath as NSString).expandingTildeInPath
    }
}

extension BackgroundWatcherStatus {

    public enum ReadError: Error, Equatable, CustomStringConvertible {
        case notJSON(String)
        case notAnObject

        public var description: String {
            switch self {
            case .notJSON(let detail): "not valid JSON: \(detail)"
            case .notAnObject: "not a JSON object"
            }
        }
    }

    /// `fallbackName` is the file's own name, for a file that doesn't say.
    public static func read(_ data: Data, fallbackName: String) throws -> BackgroundWatcherStatus {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw ReadError.notJSON(error.localizedDescription)
        }
        guard let json = object as? [String: Any] else { throw ReadError.notAnObject }

        var run: Run?
        if let last = json["lastRun"] as? [String: Any],
            let finished = date(last["finishedAt"]) ?? date(last["startedAt"])
        {
            run = Run(
                startedAt: date(last["startedAt"]),
                finishedAt: finished,
                result: Result(text(last["result"]) ?? "unknown"),
                summary: text(last["summary"]),
                error: text(last["error"])
            )
        }

        let sessions = (json["sessions"] as? [[String: Any]] ?? []).compactMap { entry -> StartedSession? in
            guard let key = entry["key"] as? String else { return nil }
            return StartedSession(
                key: key,
                name: text(entry["name"]),
                startedAt: date(entry["startedAt"]),
                reason: text(entry["reason"]),
                url: text(entry["url"])
            )
        }

        return BackgroundWatcherStatus(
            version: (json["version"] as? NSNumber)?.intValue ?? knownVersion,
            name: text(json["name"]) ?? fallbackName,
            description: text(json["description"]),
            launchdLabel: text(json["launchdLabel"]),
            schedule: schedule(json["schedule"]),
            logPath: text(json["logPath"]),
            lastRun: run,
            lastSuccessAt: date(json["lastSuccessAt"]),
            sessions: sessions
        )
    }

    static func schedule(_ value: Any?) -> Schedule? {
        guard let value = value as? [String: Any] else { return nil }
        if let every = (value["every"] as? NSNumber)?.doubleValue, every > 0 {
            return .every(every)
        }
        if let daily = value["daily"] as? String {
            let parts = daily.split(separator: ":")
            guard parts.count == 2, let hour = Int(parts[0]), let minute = Int(parts[1]),
                (0..<24).contains(hour), (0..<60).contains(minute)
            else { return nil }
            return .daily(hour: hour, minute: minute)
        }
        return nil
    }

    private static func text(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
    }

    private static func date(_ value: Any?) -> Date? {
        TranscriptTimestamp.parse(value as? String)
    }
}
