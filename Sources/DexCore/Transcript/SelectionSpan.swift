import Foundation

/// One end of a selection: which piece of the pane it lands in, and how far into
/// that piece's text.
///
/// The path is the piece's place in the conversation, an index per level — the
/// item, then the block inside it, then whatever that block holds. Two pieces
/// drawn by views that know nothing about each other still compare in reading
/// order, which is the whole of what lets a drag run from one turn into the next.
public struct SelectionPoint: Sendable, Hashable, Comparable {
    public let path: [Int]
    public let offset: Int

    public init(path: [Int], offset: Int) {
        self.path = path
        self.offset = offset
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path ? lhs.offset < rhs.offset : precedes(lhs.path, rhs.path)
    }

    static func precedes(_ lhs: [Int], _ rhs: [Int]) -> Bool {
        for (left, right) in zip(lhs, rhs) where left != right { return left < right }
        return lhs.count < rhs.count
    }
}

/// A stretch of the conversation between two points, which the pieces in the
/// middle are read off rather than told about — a piece asks what of it is taken
/// and needs to know nothing about where the drag started or where it is now.
public struct SelectionSpan: Sendable, Hashable {
    public let start: SelectionPoint
    public let end: SelectionPoint

    /// Held in reading order however it was dragged, so every piece can be asked
    /// the same question whether the drag ran down the pane or back up it.
    public init(from anchor: SelectionPoint, to focus: SelectionPoint) {
        (start, end) = anchor <= focus ? (anchor, focus) : (focus, anchor)
    }

    public var isEmpty: Bool { start == end }

    /// What this takes of the piece at `path`, in that piece's own characters.
    /// Nil for a piece the selection never reaches — including one it stops
    /// exactly at the edge of, where taking nothing and taking an empty range
    /// would otherwise look the same to a caller.
    public func range(in path: [Int], length: Int) -> Range<Int>? {
        guard !isEmpty else { return nil }

        let lower: Int
        if path == start.path {
            lower = start.offset
        } else if SelectionPoint.precedes(start.path, path) {
            lower = 0
        } else {
            return nil
        }

        let upper: Int
        if path == end.path {
            upper = end.offset
        } else if SelectionPoint.precedes(path, end.path) {
            upper = length
        } else {
            return nil
        }

        let from = min(max(lower, 0), length)
        let to = min(max(upper, 0), length)
        return from < to ? from..<to : nil
    }
}
