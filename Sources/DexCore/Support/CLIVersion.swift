import Foundation

/// A version of Claude Code, compared as numbers rather than as text so that
/// 2.1.9 sorts below 2.1.10.
public struct CLIVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
    public let parts: [Int]

    public init?(_ text: String) {
        guard let found = text.firstMatch(of: /(\d+)\.(\d+)\.(\d+)/) else { return nil }
        parts = [found.1, found.2, found.3].compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: CLIVersion, b: CLIVersion) -> Bool {
        for (left, right) in zip(a.parts, b.parts) where left != right { return left < right }
        return false
    }
}
