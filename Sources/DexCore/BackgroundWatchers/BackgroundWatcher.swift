import Foundation

/// A status file as found on disk: read, or not readable and saying why.
public struct BackgroundWatcher: Identifiable, Hashable, Sendable {

    /// The file's name without `.json`. Sessions are tied to a watcher by its
    /// `name` instead, which is what a watcher sends as `origin.watcher`.
    public let id: String
    public let file: URL
    /// When the file was last written. The clock for a watcher that has never
    /// run, since nothing else in the file dates it.
    public let modifiedAt: Date
    public let reading: Reading

    public enum Reading: Hashable, Sendable {
        case status(BackgroundWatcherStatus)
        case unreadable(String)
    }

    public init(id: String, file: URL, modifiedAt: Date, reading: Reading) {
        self.id = id
        self.file = file
        self.modifiedAt = modifiedAt
        self.reading = reading
    }

    public var status: BackgroundWatcherStatus? {
        if case .status(let status) = reading { status } else { nil }
    }

    public var name: String { status?.name ?? id }

    /// Every `*.json` in `directory`. Temp files a watcher is mid-way through
    /// renaming into place are skipped by extension.
    public static func load(from directory: URL, fileManager: FileManager = .default) -> [BackgroundWatcher] {
        let files =
            (try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return files
            .filter { $0.pathExtension == "json" }
            .map { load(file: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public static func load(file: URL) -> BackgroundWatcher {
        let id = file.deletingPathExtension().lastPathComponent
        let modified =
            (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            ?? .distantPast
        let reading: Reading
        do {
            let data = try Data(contentsOf: file)
            reading = .status(try BackgroundWatcherStatus.read(data, fallbackName: id))
        } catch let error as BackgroundWatcherStatus.ReadError {
            reading = .unreadable(error.description)
        } catch {
            reading = .unreadable(error.localizedDescription)
        }
        return BackgroundWatcher(id: id, file: file, modifiedAt: modified, reading: reading)
    }
}

public struct BackgroundWatcherHealth: Hashable, Sendable {

    public enum Condition: Hashable, Sendable {
        case ok, idle, failed, neverRan
        /// A result this build doesn't know. Shown as written, not alarmed on.
        case other(String)
        case unreadable(String)
    }

    public let condition: Condition
    /// Past when it should have run again. Independent of `condition`: a
    /// watcher whose last run failed and that has since stopped running is both.
    public let isStale: Bool
    /// From the schedule. Nil where there isn't one Dex understands.
    public let nextRunAt: Date?
    /// The file says a version newer than this build reads.
    public let isNewerFormat: Bool
    /// Overdue, but only just woken, so not called stale yet. An alert already
    /// out for it should stand rather than be read as a recovery.
    public var isHeldByWake = false

    public var needsAttention: Bool {
        switch condition {
        case .failed, .unreadable: true
        default: isStale
        }
    }

    /// What a notification is keyed on, so one goes out per problem rather than
    /// per check: the same failed run, or the same overdue run, says the same.
    /// Nil when there is nothing to say.
    public func alertToken(for watcher: BackgroundWatcher) -> String? {
        guard needsAttention else { return nil }
        let run = watcher.status?.lastRun.map { "\($0.finishedAt.timeIntervalSince1970)" } ?? "never"
        switch condition {
        case .unreadable: return "unreadable:\(watcher.modifiedAt.timeIntervalSince1970)"
        case .failed: return isStale ? "stale:\(run)" : "failed:\(run)"
        default: return "stale:\(run)"
        }
    }

    /// No watcher is stale until this long after the Mac last woke. launchd
    /// runs a job that came due during sleep once it wakes, and that run needs
    /// a moment to finish and write.
    public static let wakeGrace: TimeInterval = 10 * 60
    public static let staleFloor: TimeInterval = 10 * 60
    public static let dailyGrace: TimeInterval = 2 * 60 * 60

    public static func of(
        _ watcher: BackgroundWatcher,
        now: Date,
        lastWake: Date? = nil,
        calendar: Calendar = .current
    ) -> BackgroundWatcherHealth {
        guard let status = watcher.status else {
            let reason = if case .unreadable(let why) = watcher.reading { why } else { "" }
            return BackgroundWatcherHealth(
                condition: .unreadable(reason), isStale: false, nextRunAt: nil, isNewerFormat: false
            )
        }

        let condition: Condition =
            switch status.lastRun?.result {
            case nil: .neverRan
            case .ok: .ok
            case .idle: .idle
            case .failed: .failed
            case .other(let raw): .other(raw)
            }

        let reference = status.lastRun?.finishedAt ?? watcher.modifiedAt
        var stale = false
        var next: Date?
        switch status.schedule {
        case .every(let interval):
            stale = now.timeIntervalSince(reference) > max(3 * interval, staleFloor)
            let from = status.lastRun.map { $0.startedAt ?? $0.finishedAt }
            next = from.map { max($0.addingTimeInterval(interval), now) }
        case .daily(let hour, let minute):
            if let due = mostRecent(hour: hour, minute: minute, atOrBefore: now, calendar: calendar) {
                stale = now >= due.addingTimeInterval(dailyGrace) && reference < due
            }
            next = calendar.nextDate(
                after: now,
                matching: DateComponents(hour: hour, minute: minute),
                matchingPolicy: .nextTime
            )
        case nil:
            break
        }
        var held = false
        if stale, let lastWake, now.timeIntervalSince(lastWake) < wakeGrace {
            stale = false
            held = true
        }

        return BackgroundWatcherHealth(
            condition: condition,
            isStale: stale,
            nextRunAt: next,
            isNewerFormat: status.version > BackgroundWatcherStatus.knownVersion,
            isHeldByWake: held
        )
    }

    static func mostRecent(hour: Int, minute: Int, atOrBefore now: Date, calendar: Calendar) -> Date? {
        guard let today = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) else {
            return nil
        }
        return today <= now ? today : calendar.date(byAdding: .day, value: -1, to: today)
    }
}

extension BackgroundWatcher {

    /// The last `lines` lines of a log, reading only its tail.
    public static func logTail(path: String, lines: Int = 10, bytes: Int = 16 * 1024) -> [String]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var all = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        // A read that starts mid-file starts mid-line.
        if start > 0, !all.isEmpty { all.removeFirst() }
        while all.last?.isEmpty == true { all.removeLast() }
        return Array(all.suffix(lines))
    }
}
