import Observation

/// Which folds in a transcript are open, held outside the rows that draw them.
/// The column builds a row's view as it scrolls in and throws it away as it
/// scrolls out, so a fold kept in the row's own state shut every time it did.
///
/// One for the app, keyed by what each fold belongs to: call, run and message
/// ids are unique across every transcript, so two panes never share a key.
@MainActor
@Observable
package final class RowExpansions {
    package static let shared = RowExpansions()

    /// The folds turned away from how they open.
    private var turned: Set<String> = []

    func isExpanded(_ key: String, opensExpanded: Bool = false) -> Bool {
        turned.contains(key) != opensExpanded
    }

    package func toggle(_ key: String) {
        if turned.remove(key) == nil { turned.insert(key) }
        turnedAt = .now
    }

    /// When a fold was last turned, so a column can tell a row that changed
    /// height because it was opened from one that changed because it was
    /// written to.
    @ObservationIgnored private(set) var turnedAt: ContinuousClock.Instant?
}
