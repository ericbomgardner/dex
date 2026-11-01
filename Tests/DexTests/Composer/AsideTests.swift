import XCTest
@testable import DexCore

final class AsideTests: XCTestCase {

    func testBtwAtTheStartIsASideQuestion() {
        XCTAssertEqual(Aside.question(in: "/btw where is the config read?"), "where is the config read?")
        XCTAssertEqual(Aside.question(in: "  /btw\nmultiline\nquestion "), "multiline\nquestion")
    }

    func testBtwWithNothingAfterItIsEmptyRatherThanAMessage() {
        XCTAssertEqual(Aside.question(in: "/btw"), "")
        XCTAssertEqual(Aside.question(in: "/btw   "), "")
    }

    func testAnythingElseIsAMessage() {
        XCTAssertNil(Aside.question(in: "/btwx what"))
        XCTAssertNil(Aside.question(in: "btw what"))
        XCTAssertNil(Aside.question(in: "fix it /btw later"))
        XCTAssertNil(Aside.question(in: "/review"))
    }

    func testAnAnswerBecomesAnExchange() {
        var aside = Aside()
        let id = aside.ask("one?")
        XCTAssertEqual(aside.pending?.question, "one?")

        aside.answered(id, with: "yes")

        XCTAssertNil(aside.pending)
        XCTAssertEqual(aside.exchanges, [SideExchange(question: "one?", response: "yes")])
    }

    func testANewerQuestionDropsTheOlderAnswer() {
        var aside = Aside()
        let first = aside.ask("one?")
        let second = aside.ask("two?")

        aside.answered(first, with: "late")
        XCTAssertEqual(aside.pending?.question, "two?")
        XCTAssertTrue(aside.exchanges.isEmpty)

        aside.answered(second, with: "on time")
        XCTAssertEqual(aside.exchanges.map(\.response), ["on time"])
    }

    func testAFailureKeepsTheQuestionAndClearsOnTheNextAsk() {
        var aside = Aside()
        let id = aside.ask("one?")
        aside.failed(id, because: "no such session")

        XCTAssertEqual(aside.failure, Aside.Failure(question: "one?", reason: "no such session"))
        XCTAssertNil(aside.pending)

        _ = aside.ask("again?")
        XCTAssertNil(aside.failure)
    }

    func testQuotedCarriesEveryExchange() {
        var aside = Aside()
        let a = aside.ask("a?")
        aside.answered(a, with: "A")
        let b = aside.ask("b?")
        aside.answered(b, with: "B")

        XCTAssertEqual(
            aside.quoted,
            "I asked on the side: a?\n\nThe answer was:\nA\n\nI asked on the side: b?\n\nThe answer was:\nB"
        )
    }
}
