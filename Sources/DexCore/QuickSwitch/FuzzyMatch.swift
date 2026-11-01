import Foundation

/// Subsequence matching over short display names, scored so that word starts and
/// unbroken runs beat characters scattered through the middle of a name.
public enum FuzzyMatch {

    public struct Match: Sendable, Hashable {

        public let score: Int

        /// Indices of the candidate's characters the query landed on.
        public let matched: [Int]

        public init(score: Int, matched: [Int]) {
            self.score = score
            self.matched = matched
        }
    }

    private enum Weight {
        static let character = 8
        static let start = 12
        static let wordStart = 9
        static let camelHump = 7
        static let consecutive = 10
        static let gapStart = -5
        static let gapExtension = -1
    }

    private static let unreachable = Int.min / 4

    public static func match(_ query: String, in candidate: String) -> Match? {
        let needle = folded(query.filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return Match(score: 0, matched: []) }

        let characters = Array(candidate)
        let lowered = folded(candidate)
        guard needle.count <= lowered.count else { return nil }

        return solve(needle: needle, lowered: lowered, characters: characters)
    }

    /// Per character, so an index into the lowered form still indexes the original.
    private static func folded(_ text: String) -> [Character] {
        text.map { $0.lowercased().first ?? $0 }
    }

    private static func solve(
        needle: [Character],
        lowered: [Character],
        characters: [Character]
    ) -> Match? {
        let rows = needle.count
        let columns = lowered.count

        var previous = [Int](repeating: unreachable, count: columns)
        var current = [Int](repeating: unreachable, count: columns)
        var parents = [[Int]](repeating: [Int](repeating: -1, count: columns), count: rows)

        for i in 0..<rows {
            var carry = unreachable
            var carryFrom = -1

            for j in 0..<columns {
                (carry, carryFrom) = advance(
                    carry: carry,
                    carryFrom: carryFrom,
                    row: i,
                    column: j,
                    previous: previous
                )

                guard needle[i] == lowered[j] else {
                    current[j] = unreachable
                    continue
                }

                var best = carry
                var from = carryFrom
                if i > 0, j > 0, previous[j - 1] != unreachable {
                    let consecutive = previous[j - 1] + Weight.consecutive
                    if consecutive > best {
                        best = consecutive
                        from = j - 1
                    }
                }

                guard best != unreachable else {
                    current[j] = unreachable
                    continue
                }
                current[j] = best + Weight.character + bonus(at: j, in: characters)
                parents[i][j] = from
            }

            previous = current
            current = [Int](repeating: unreachable, count: columns)
        }

        guard let end = bestColumn(in: previous) else { return nil }
        return Match(score: previous[end], matched: trace(from: end, parents: parents))
    }

    private static func advance(
        carry: Int,
        carryFrom: Int,
        row: Int,
        column: Int,
        previous: [Int]
    ) -> (Int, Int) {
        guard column > 0 else {
            return (row == 0 ? 0 : unreachable, -1)
        }
        guard row > 0 else {
            return (Weight.gapExtension * column, -1)
        }

        let extended = carry == unreachable ? unreachable : carry + Weight.gapExtension
        let opened = previous[column - 1] == unreachable
            ? unreachable
            : previous[column - 1] + Weight.gapStart

        return opened >= extended ? (opened, column - 1) : (extended, carryFrom)
    }

    private static func bestColumn(in scores: [Int]) -> Int? {
        var best: Int?
        for (column, score) in scores.enumerated() where score != unreachable {
            if let found = best, scores[found] >= score { continue }
            best = column
        }
        return best
    }

    private static func trace(from end: Int, parents: [[Int]]) -> [Int] {
        var matched: [Int] = []
        var column = end
        for row in stride(from: parents.count - 1, through: 0, by: -1) {
            matched.append(column)
            let parent = parents[row][column]
            guard parent >= 0 else { break }
            column = parent
        }
        return matched.reversed()
    }

    private static func bonus(at index: Int, in characters: [Character]) -> Int {
        guard index > 0 else { return Weight.start }

        let previous = characters[index - 1]
        if !previous.isLetter, !previous.isNumber { return Weight.wordStart }

        let current = characters[index]
        if current.isUppercase, previous.isLowercase || previous.isNumber { return Weight.camelHump }

        return 0
    }
}
