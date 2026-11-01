import XCTest

@testable import DexCore

final class HostFramingTests: XCTestCase {

    private func lines(_ framing: inout HostFraming, _ text: String) -> [String] {
        framing.consume(Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
    }

    func testSeveralEventsInOneReadComeOutSeparately() {
        var framing = HostFraming()
        XCTAssertEqual(lines(&framing, "{\"a\":1}\n{\"b\":2}\n"), ["{\"a\":1}", "{\"b\":2}"])
    }

    func testAnEventSplitAcrossReadsIsHeldUntilItIsWhole() {
        var framing = HostFraming()
        XCTAssertEqual(lines(&framing, "{\"a\":"), [])
        XCTAssertEqual(lines(&framing, "1}"), [])
        XCTAssertEqual(lines(&framing, "\n"), ["{\"a\":1}"])
    }

    func testATrailingPartialSurvivesTheEventsBeforeIt() {
        var framing = HostFraming()
        XCTAssertEqual(lines(&framing, "{\"a\":1}\n{\"b\":"), ["{\"a\":1}"])
        XCTAssertEqual(lines(&framing, "2}\n"), ["{\"b\":2}"])
    }

    func testBlankLinesAreNotEvents() {
        var framing = HostFraming()
        XCTAssertEqual(lines(&framing, "\n\n{\"a\":1}\n\n"), ["{\"a\":1}"])
    }

    func testAPayloadLargerThanOneReadStillArrivesIntact() {
        var framing = HostFraming()
        let preview = String(repeating: "x", count: 200_000)
        let whole = "{\"preview\":\"\(preview)\"}"

        var produced: [String] = []
        for chunk in stride(from: 0, to: whole.count, by: 8192).map({ offset -> String in
            let start = whole.index(whole.startIndex, offsetBy: offset)
            let end = whole.index(start, offsetBy: min(8192, whole.count - offset))
            return String(whole[start..<end])
        }) {
            produced += lines(&framing, chunk)
        }
        XCTAssertEqual(produced, [])
        XCTAssertEqual(lines(&framing, "\n"), [whole])
    }

    func testAPeerThatNeverEndsALineIsGivenUpOnRatherThanGrownInto() {
        var framing = HostFraming()
        let megabyte = String(repeating: "x", count: 1_000_000)
        for _ in 0..<9 { _ = lines(&framing, megabyte) }

        XCTAssertTrue(framing.overflowed)
        XCTAssertEqual(lines(&framing, "{\"a\":1}\n"), [], "a framing that gave up stays given up")

        framing.reset()
        XCTAssertFalse(framing.overflowed)
        XCTAssertEqual(lines(&framing, "{\"a\":1}\n"), ["{\"a\":1}"])
    }
}
