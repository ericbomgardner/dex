import Foundation
import Testing
@testable import DexCore

/// The two pieces of opening a transcript that were rewritten for speed, held
/// to what they replaced.
@Suite("Reading a transcript fast")
struct TranscriptReadingSpeedTests {

    /// What `completeLines` was before: `split` over the complete part.
    private func reference(_ data: Data) -> (lines: [Data], consumed: Int) {
        guard let lastBreak = data.lastIndex(of: UInt8(ascii: "\n")) else { return ([], 0) }
        let complete = data[data.startIndex...lastBreak]
        return (complete.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true), complete.count)
    }

    @Test("Lines come back as split found them", arguments: [
        "", "no break", "\n", "\n\n\n", "one\n", "one\ntwo\n", "one\n\ntwo\npartial",
        "{\"a\":1}\n{\"b\":2}\n{\"c\":", "\nleading\n", "trailing\n\n", "é ünïcode\n✓ done\n",
    ])
    func linesMatchSplit(_ text: String) {
        let data = Data(text.utf8)
        let ours = TranscriptTail.completeLines(in: data)
        let theirs = reference(data)
        #expect(ours.consumed == theirs.consumed)
        #expect(ours.lines == theirs.lines)
    }

    @Test("Lines from the middle of a larger buffer keep their offsets")
    func linesFromASlice() {
        let whole = Data("skip\nfirst\nsecond\nthird".utf8)
        let slice = whole[5...]
        let ours = TranscriptTail.completeLines(in: slice)
        let theirs = reference(slice)
        #expect(ours.consumed == theirs.consumed)
        #expect(ours.lines.map { String(decoding: $0, as: UTF8.self) } == ["first", "second"])
        #expect(ours.lines == theirs.lines)
    }

    @Test("Random buffers split the same way")
    func randomBuffers() {
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            let bytes = (0..<Int.random(in: 0...300, using: &generator)).map { _ -> UInt8 in
                Bool.random(using: &generator) && Int.random(in: 0..<4, using: &generator) == 0
                    ? UInt8(ascii: "\n") : UInt8.random(in: 32...126, using: &generator)
            }
            let data = Data(bytes)
            let ours = TranscriptTail.completeLines(in: data)
            let theirs = reference(data)
            #expect(ours.consumed == theirs.consumed)
            #expect(ours.lines == theirs.lines)
        }
    }

    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    @Test("The CLI's own shape reads the same as the formatter reads it")
    func timestampsMatchTheFormatter() {
        var generator = SystemRandomNumberGenerator()
        let shape = DateFormatter()
        shape.locale = Locale(identifier: "en_US_POSIX")
        shape.timeZone = TimeZone(identifier: "UTC")
        shape.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        for _ in 0..<20_000 {
            let date = Date(timeIntervalSince1970: Double.random(in: 0...4_102_444_800, using: &generator))
            let text = shape.string(from: date)
            let ours = TranscriptTimestamp.utc(text)
            let theirs = Self.formatter.date(from: text)
            #expect(ours != nil)
            #expect(abs((ours?.timeIntervalSince1970 ?? 0) - (theirs?.timeIntervalSince1970 ?? 1)) < 0.000_5, "\(text)")
        }
    }

    @Test("Edges of the calendar", arguments: [
        "2024-02-29T23:59:59.999Z", "2000-01-01T00:00:00.000Z", "1970-01-01T00:00:00.000Z",
        "2026-12-31T12:00:00.5Z", "2026-10-15T04:37:41Z", "2100-03-01T00:00:00.000Z",
    ])
    func calendarEdges(_ text: String) {
        let ours = TranscriptTimestamp.parse(text)
        let whole = ISO8601DateFormatter()
        let theirs = Self.formatter.date(from: text) ?? whole.date(from: text)
        #expect(ours != nil)
        #expect(abs((ours?.timeIntervalSince1970 ?? 0) - (theirs?.timeIntervalSince1970 ?? 1)) < 0.000_5)
    }

    @Test("Anything else goes to the formatter, or to nothing", arguments: [
        "2026-10-15T04:37:41.123+01:00", "2026-10-15 04:37:41Z", "2026-13-01T00:00:00Z",
        "garbage", "2026-10-15T04:37:41.Z", "2026-10-15T04:37", "",
    ])
    func otherShapes(_ text: String) {
        #expect(TranscriptTimestamp.utc(text) == nil)
        let theirs = Self.formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        #expect(TranscriptTimestamp.parse(text) == theirs)
    }
}
