import Foundation

/// Collapses a burst of file-system events into one call. A single write can
/// arrive as several events, and every one of them would otherwise cost a read.
@MainActor
final class Debounce {
    static let interval = Duration.milliseconds(400)

    private var tasks: [String: Task<Void, Never>] = [:]

    /// Calls `body` once the events stop, per key. Later calls under the same key
    /// replace the pending one.
    func callAsFunction(_ key: String = "", _ body: @escaping @MainActor () -> Void) {
        tasks[key]?.cancel()
        tasks[key] = Task {
            try? await Task.sleep(for: Self.interval)
            guard !Task.isCancelled else { return }
            body()
        }
    }

    func cancel(_ key: String) {
        tasks.removeValue(forKey: key)?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}
