import Foundation

/// The transcript writes ISO 8601 with fractional seconds, but not on every
/// record, so both shapes parse.
enum TranscriptTimestamp {

    nonisolated(unsafe) private static let withFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let wholeSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    static func parse(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let date = utc(value) { return date }
        return withFractionalSeconds.date(from: value) ?? wholeSeconds.date(from: value)
    }

    /// The shape the CLI writes every record in — `2026-10-15T04:37:41.123Z` —
    /// read by hand. The formatter is general and slow, and a long transcript
    /// has a timestamp on every line; anything else still goes to it.
    static func utc(_ value: String) -> Date? {
        var utf8 = value.utf8
        return utf8.withContiguousStorageIfAvailable { bytes -> Date? in
            func digits(_ at: Int, _ count: Int) -> Int? {
                guard at + count <= bytes.count else { return nil }
                var number = 0
                for index in at..<(at + count) {
                    let byte = bytes[index]
                    guard byte >= 48, byte <= 57 else { return nil }
                    number = number * 10 + Int(byte - 48)
                }
                return number
            }
            func is_(_ at: Int, _ character: Character) -> Bool {
                at < bytes.count && bytes[at] == character.asciiValue!
            }
            guard bytes.count >= 20,
                  let year = digits(0, 4), is_(4, "-"), let month = digits(5, 2), is_(7, "-"),
                  let day = digits(8, 2), is_(10, "T"), let hour = digits(11, 2), is_(13, ":"),
                  let minute = digits(14, 2), is_(16, ":"), let second = digits(17, 2),
                  (1...12).contains(month), (1...31).contains(day), hour < 24, minute < 60, second < 61
            else { return nil }

            var at = 19
            var fraction = 0.0
            if is_(at, ".") {
                at += 1
                var scale = 0.1
                let first = at
                while at < bytes.count, bytes[at] >= 48, bytes[at] <= 57 {
                    fraction += Double(bytes[at] - 48) * scale
                    scale /= 10
                    at += 1
                }
                guard at > first else { return nil }
            }
            guard at == bytes.count - 1, is_(at, "Z") else { return nil }

            // Days from the civil date, after Howard Hinnant's algorithm.
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yearOfEra = y - era * 400
            let dayOfYear = (153 * (month > 2 ? month - 3 : month + 9) + 2) / 5 + day - 1
            let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
            let days = era * 146_097 + dayOfEra - 719_468
            let seconds = Double(days * 86_400 + hour * 3_600 + minute * 60 + second) + fraction
            return Date(timeIntervalSince1970: seconds)
        } ?? nil
    }
}
