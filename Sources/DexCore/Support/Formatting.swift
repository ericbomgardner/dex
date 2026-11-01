import Foundation

public enum Format {
    private static let secondsPerMinute = 60.0
    private static let secondsPerHour = 3600.0
    private static let secondsPerDay = 86_400.0

    public static func age(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds >= secondsPerMinute else { return "<1m" }
        return coarse(seconds)
    }

    public static func preciseAge(since date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        guard seconds >= secondsPerMinute else { return "\(Int(seconds))s" }
        return coarse(seconds)
    }

    /// How long something took, written the way the CLI writes it — read off
    /// **v2.1.221**, so a subagent's run reads the same in the pane as it did in
    /// the terminal. Past an hour it goes on to hours, which the terminal doesn't.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds).rounded())
        guard whole >= Int(secondsPerMinute) else { return "\(whole)s" }

        let hours = whole / Int(secondsPerHour)
        let minutes = whole % Int(secondsPerHour) / Int(secondsPerMinute)
        let seconds = whole % Int(secondsPerMinute)
        var parts = hours > 0 ? ["\(hours)h", "\(minutes)m", "\(seconds)s"] : ["\(minutes)m", "\(seconds)s"]
        while parts.count > 1, parts.last?.hasPrefix("0") == true { parts.removeLast() }
        return parts.joined(separator: " ")
    }

    /// A count big enough that its last digits say nothing — enough to weigh two
    /// against each other, not enough to read as an invoice.
    public static func compact(_ value: Int) -> String {
        guard value >= 1_000 else { return "\(value)" }

        let thousands = tenths(Double(value) / 1_000)
        // Scaling before rounding is what puts a hair under a million into the
        // wrong unit, as "1000k".
        guard thousands >= 1_000 else { return scaled(thousands, "k") }
        return scaled(tenths(thousands / 1_000), "M")
    }

    /// A small amount of money, in the same tone as `compact` — enough to weigh
    /// two against each other, not enough to read as an invoice. Cents under a
    /// dollar, because the numbers this is for are mostly pennies and "$0.09"
    /// reads as a rounding error rather than as something paid every turn.
    public static func money(_ dollars: Double) -> String {
        let cents = (max(0, dollars) * 100).rounded()
        guard cents >= 100 else { return "\(Int(cents))¢" }
        return String(format: "$%.2f", cents / 100)
    }

    private static func tenths(_ value: Double) -> Double { (value * 10).rounded() / 10 }

    private static func scaled(_ value: Double, _ suffix: String) -> String {
        let text = value == value.rounded()
            ? "\(Int(value))"
            : String(format: "%.1f", value)
        return text + suffix
    }

    private static func coarse(_ seconds: TimeInterval) -> String {
        switch seconds {
        case ..<secondsPerHour:
            return "\(Int(seconds / secondsPerMinute))m"
        case ..<secondsPerDay:
            return "\(Int(seconds / secondsPerHour))h"
        default:
            return "\(Int(seconds / secondsPerDay))d"
        }
    }

    public static func tildePath(_ path: String, home: String = NSHomeDirectory()) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func shortPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        let display = tildePath(path, home: home)
        if display == "~" { return display }
        let components = display.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count > 3 else { return display }
        return "…/" + components.suffix(2).joined(separator: "/")
    }
}
