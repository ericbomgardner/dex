import DexCore
import Foundation
import os

/// Timing lines for a session switch, kept by the system log under the
/// subsystem `BundleIdentity.code`, like every other line the app logs, and
/// read back with `log show --predicate 'category == "timing"' --last 10m`.
package enum Timing {
    static let logger = Logger(subsystem: BundleIdentity.code, category: "timing")

    package static func ms(_ duration: Duration) -> String {
        let parts = duration.components
        let ms = Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
        return String(format: "%.0fms", ms)
    }

    @MainActor
    static func log(_ what: String, feed: TranscriptFeed) {
        guard let switched = feed.switchedAt else { return }
        let now = ContinuousClock.now
        let sinceItems = feed.firstItemsAt.map { " (\(ms(now - $0)) after items)" } ?? ""
        logger.notice("switch: \(what, privacy: .public) \(ms(now - switched), privacy: .public) after switch\(sinceItems, privacy: .public)")
    }
}
