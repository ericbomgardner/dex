import DexCore
import AppKit
import Foundation
import Observation

/// The launchd jobs that start sessions on their own, as their status files in
/// `~/.claude/dex/watchers` describe them. Not the `Monitor` tasks `TranscriptWatcher`
/// and `HostTask.isWatcher` are about.
@MainActor
@Observable
final class BackgroundWatchers {

    private(set) var watchers: [BackgroundWatcher] = []

    /// Moved on every tick, since staleness changes with nothing written.
    private(set) var now = Date()

    private(set) var lastWake: Date?

    /// What `launchctl print` said, for the watchers it was asked about.
    private(set) var launchd: [String: LaunchdState] = [:]

    /// Called after every reload, for alerts and the rows' origins.
    @ObservationIgnored var onChange: (() -> Void)?

    let directory: URL

    @ObservationIgnored private var source: (any DispatchSourceFileSystemObject)?
    @ObservationIgnored private var tick: Task<Void, Never>?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private let debounce = Debounce()

    static let tickInterval = Duration.seconds(60)

    init(directory: URL = SupportDirectory.url().appendingPathComponent("watchers")) {
        self.directory = directory
    }

    func start() {
        reload()
        tick = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.tickInterval)
                self?.reload()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    func stop() {
        tick?.cancel()
        tick = nil
        source?.cancel()
        source = nil
        debounce.cancelAll()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
    }

    func reload() {
        now = Date()
        lastWake = Self.lastWakeTime()
        watchers = BackgroundWatcher.load(from: directory)
        // The directory may not exist until the first watcher writes into it,
        // so the tick keeps trying.
        if source == nil { watchDirectory() }
        for watcher in watchers where health(of: watcher).isStale {
            refreshLaunchd(for: watcher)
        }
        onChange?()
    }

    func health(of watcher: BackgroundWatcher) -> BackgroundWatcherHealth {
        BackgroundWatcherHealth.of(watcher, now: now, lastWake: lastWake)
    }

    var needingAttention: [BackgroundWatcher] {
        watchers.filter { health(of: $0).needsAttention }
    }

    /// Host key to origin, from each file's `sessions`: how a row started by a
    /// host too old to carry `origin` is still tied to its watcher.
    var originsByKey: [String: SessionOrigin] {
        var origins: [String: SessionOrigin] = [:]
        for watcher in watchers {
            guard let status = watcher.status else { continue }
            for session in status.sessions where !session.key.isEmpty && origins[session.key] == nil {
                origins[session.key] = SessionOrigin(watcher: status.name, reason: session.reason)
            }
        }
        return origins
    }

    // MARK: launchd

    struct LaunchdState: Hashable {
        var loaded: Bool
        var detail: String?
    }

    func refreshLaunchd(for watcher: BackgroundWatcher) {
        guard let label = watcher.status?.launchdLabel else { return }
        let target = Self.target(label)
        Task.detached {
            let state = Self.launchdState(target: target)
            await MainActor.run { [weak self] in self?.launchd[label] = state }
        }
    }

    /// Runs the job now, whatever its schedule says.
    func runNow(_ watcher: BackgroundWatcher, done: @escaping @MainActor (String?) -> Void) {
        guard let label = watcher.status?.launchdLabel else { return done("No launchd label in its status file") }
        let target = Self.target(label)
        Task.detached {
            let error: String? =
                if let result = try? Shell.run(["launchctl", "kickstart", target], timeout: 10) {
                    result.exitCode == 0
                        ? nil
                        : result.stderr.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
                            ?? "launchctl exited \(result.exitCode)"
                } else {
                    "launchctl didn't run"
                }
            await MainActor.run { done(error) }
        }
    }

    private nonisolated static func target(_ label: String) -> String {
        "gui/\(getuid())/\(label)"
    }

    private nonisolated static func launchdState(target: String) -> LaunchdState {
        guard let result = try? Shell.run(["launchctl", "print", target], timeout: 10) else {
            return LaunchdState(loaded: false, detail: "launchctl didn't run")
        }
        guard result.exitCode == 0 else { return LaunchdState(loaded: false, detail: nil) }
        let wanted = ["state = ", "last exit code = "]
        let lines = result.stdoutText.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in wanted.contains { line.hasPrefix($0) } }
        return LaunchdState(loaded: true, detail: lines.isEmpty ? nil : Array(Set(lines)).sorted().joined(separator: ", "))
    }

    // MARK: Files

    private func watchDirectory() {
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if source.data.contains(.delete) || source.data.contains(.rename) {
                    self.source?.cancel()
                    self.source = nil
                }
                self.debounce { [weak self] in self?.reload() }
            }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    /// When the Mac last woke, from the kernel rather than a notification, so it
    /// is known even when Dex was launched after the wake.
    private static func lastWakeTime() -> Date? {
        var value = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.waketime", &value, &size, nil, 0) == 0, value.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(value.tv_sec) + TimeInterval(value.tv_usec) / 1_000_000)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
