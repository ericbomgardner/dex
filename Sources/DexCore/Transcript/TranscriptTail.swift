import Foundation

/// Reads a transcript forward from where it last stopped. Sessions append for
/// hours, so re-reading the whole file on every write would grow with the
/// session; this reads only what arrived since.
public struct TranscriptTail: Sendable {
    public let url: URL

    public private(set) var offset: UInt64 = 0

    public init(url: URL, offset: UInt64 = 0) {
        self.url = url
        self.offset = offset
    }

    public struct Batch: Sendable {
        public var lines: [Data] = []

        /// The file shrank, so it isn't the one we were reading. Whatever was
        /// parsed from it is stale and the caller starts over.
        public var restarted = false
    }

    public mutating func read() -> Batch {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Batch() }
        defer { try? handle.close() }

        var batch = Batch()

        let end = (try? handle.seekToEnd()) ?? 0
        if end < offset {
            offset = 0
            batch.restarted = true
        }
        guard end > offset else { return batch }

        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.readToEnd(),
              !data.isEmpty
        else { return batch }

        let (lines, consumed) = Self.completeLines(in: data)
        offset += UInt64(consumed)
        batch.lines = lines
        return batch
    }

    /// The whole records in a chunk, and how many bytes they took.
    ///
    /// A line still being written has no terminator yet, so it is left where it
    /// is and picked up whole on the next read — which is why `consumed` is
    /// answered rather than `data.count`: it is where the next read starts.
    /// The same rule for a file read from disk and one read over the socket.
    public static func completeLines(in data: Data) -> (lines: [Data], consumed: Int) {
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }

        let complete = data[data.startIndex...lastBreak]
        // Found with memchr rather than `split`, which reads a 20MB file a
        // byte at a time through `Data`'s subscript and was half of opening it.
        var lines: [Data] = []
        complete.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) in
            guard let base = bytes.baseAddress else { return }
            var start = 0
            while start < bytes.count {
                let rest = bytes.count - start
                let end = memchr(base + start, Int32(UInt8(ascii: "\n")), rest)
                    .map { $0 - UnsafeMutableRawPointer(mutating: base) } ?? bytes.count
                if end > start {
                    lines.append(complete[(complete.startIndex + start)..<(complete.startIndex + end)])
                }
                start = end + 1
            }
        }
        return (lines, complete.count)
    }
}
