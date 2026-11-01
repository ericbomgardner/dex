import Foundation

/// Cuts a socket's byte stream into the lines the host writes.
///
/// A read is not a message: a chunk can carry half an event, several events, or
/// an event and the start of the next. Decoding whatever a read happened to
/// contain is how a big ask — one carrying four options' worth of HTML preview —
/// reads as malformed while a small one works.
public struct HostFraming: Sendable {
    private var buffer = Data()

    /// Refuses to grow without bound on a peer that never sends a newline.
    public static let limit = 8 * 1024 * 1024

    public init() {}

    public private(set) var overflowed = false

    public mutating func consume(_ chunk: Data) -> [Data] {
        guard !overflowed else { return [] }

        buffer.append(chunk)
        if buffer.count > Self.limit {
            overflowed = true
            buffer.removeAll(keepingCapacity: false)
            return []
        }

        var lines: [Data] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = buffer[buffer.index(after: newline)...]
            if !line.isEmpty { lines.append(Data(line)) }
        }
        // Re-based so the running buffer doesn't keep the whole stream's storage alive.
        buffer = Data(buffer)
        return lines
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        overflowed = false
    }
}
