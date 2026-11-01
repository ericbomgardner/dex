import XCTest
@testable import DexCore

final class TranscriptTailTests: XCTestCase {
    private var url: URL!

    override func setUpWithError() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tail-\(UUID().uuidString).jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: url)
    }

    private func write(_ text: String) throws {
        try Data(text.utf8).write(to: url)
    }

    private func lines(_ batch: TranscriptTail.Batch) -> [String] {
        batch.lines.map { String(decoding: $0, as: UTF8.self) }
    }

    func testAMissingFileReadsAsNothing() {
        var tail = TranscriptTail(url: url)
        XCTAssertTrue(tail.read().lines.isEmpty)
    }

    func testReadsWholeLines() throws {
        try write("one\ntwo\n")
        var tail = TranscriptTail(url: url)
        XCTAssertEqual(lines(tail.read()), ["one", "two"])
    }

    func testReadsOnlyWhatArrivedSinceTheLastPass() throws {
        try write("one\n")
        var tail = TranscriptTail(url: url)
        XCTAssertEqual(lines(tail.read()), ["one"])

        try write("one\ntwo\n")
        XCTAssertEqual(lines(tail.read()), ["two"])
    }

    func testAnUnchangedFileYieldsNothing() throws {
        try write("one\n")
        var tail = TranscriptTail(url: url)
        _ = tail.read()
        XCTAssertTrue(tail.read().lines.isEmpty)
    }

    func testHoldsBackALineThatIsStillBeingWritten() throws {
        try write("one\n{\"partial\":")
        var tail = TranscriptTail(url: url)
        XCTAssertEqual(lines(tail.read()), ["one"])

        try write("one\n{\"partial\":true}\n")
        XCTAssertEqual(lines(tail.read()), ["{\"partial\":true}"])
    }

    func testAFileWithNoCompleteLineYieldsNothing() throws {
        try write("no terminator yet")
        var tail = TranscriptTail(url: url)
        let batch = tail.read()
        XCTAssertTrue(batch.lines.isEmpty)
        XCTAssertEqual(tail.offset, 0, "nothing was consumed, so nothing advanced")
    }

    func testAShrunkFileIsReadFromTheTop() throws {
        try write("one\ntwo\nthree\n")
        var tail = TranscriptTail(url: url)
        _ = tail.read()

        try write("fresh\n")
        let batch = tail.read()
        XCTAssertTrue(batch.restarted)
        XCTAssertEqual(lines(batch), ["fresh"])
    }

    func testOffsetTracksWhatWasConsumed() throws {
        try write("one\ntwo\n")
        var tail = TranscriptTail(url: url)
        _ = tail.read()
        XCTAssertEqual(tail.offset, 8)
    }

    // MARK: - completeLines

    /// A record still being written is left for the next read whole.
    func testAnUnfinishedLineIsHeldBackAndItsBytesAreNotConsumed() {
        let data = Data("{\"a\":1}\n{\"b\":2}\n{\"half\"".utf8)
        let (lines, consumed) = TranscriptTail.completeLines(in: data)

        XCTAssertEqual(lines.map { String(data: $0, encoding: .utf8) }, ["{\"a\":1}", "{\"b\":2}"])
        XCTAssertEqual(consumed, 16)
        XCTAssertEqual(
            String(data: data.dropFirst(consumed), encoding: .utf8), "{\"half\"",
            "the next read has to start where this one stopped, not at the end")
    }

    func testASingleWholeLineIsConsumedWhole() {
        let (lines, consumed) = TranscriptTail.completeLines(in: Data("{\"a\":1}\n".utf8))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(consumed, 8)
    }

    /// Nothing whole yet is nothing read: consuming what was seen would skip
    /// the record when its terminator arrived.
    func testNothingWholeConsumesNothing() {
        for chunk in [Data(), Data("{\"a\":1}".utf8)] {
            let (lines, consumed) = TranscriptTail.completeLines(in: chunk)
            XCTAssertTrue(lines.isEmpty)
            XCTAssertEqual(consumed, 0)
        }
    }
}
