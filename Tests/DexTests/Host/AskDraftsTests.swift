import XCTest

@testable import DexCore

private func ask(_ id: String, key: String = "s1", _ texts: [String]) -> HostAsk {
    HostAsk(
        askId: id,
        key: key,
        kind: .question,
        toolName: "AskUserQuestion",
        input: .object([
            "questions": .array(texts.map {
                .object([
                    "question": .string($0),
                    "header": .string("Scope"),
                    "options": .array([
                        .object(["label": .string("One"), "description": .string("the first")]),
                    ]),
                ])
            })
        ]),
        options: []
    )
}

/// What is written into a run of questions, and what survives what.
final class AskDraftsTests: XCTestCase {

    func testAPageWithNothingWrittenIntoItIsNotKept() {
        var drafts = AskDrafts()
        drafts["page"].typed = ""
        XCTAssertTrue(drafts.isEmpty)
    }

    func testAFieldOpenedAndLeftBlankIsKept() {
        var drafts = AskDrafts()
        drafts["page"].isWritingOwn = true
        XCTAssertFalse(drafts.isEmpty)
        XCTAssertTrue(drafts["page"].isWritingOwn)
    }

    func testAnAnswerEmptiedLeavesNothingBehind() {
        var drafts = AskDrafts()
        drafts["page"].typed = "something"
        drafts["page"].typed = ""
        XCTAssertTrue(drafts.isEmpty)
    }

    func testTwoAsksWordingAQuestionTheSameWayAreHeldApart() {
        let pages = AskPages.read([ask("a1", ["Which?"]), ask("a2", ["Which?"])])
        var drafts = AskDrafts()
        drafts[pages[0].id].typed = "the first"
        drafts[pages[1].id].typed = "the second"

        XCTAssertEqual(drafts[pages[0].id].typed, "the first")
        XCTAssertEqual(drafts[pages[1].id].typed, "the second")
    }

    /// The prune. An ask that has been answered or withdrawn takes what was
    /// written into it, and nothing else does.
    func testAnAnsweredAskTakesItsOwnAnswersOnly() {
        let mine = AskPages.read([ask("a1", ["Which?"])])
        let theirs = AskPages.read([ask("a2", key: "s2", ["Where?"])])

        var drafts = AskDrafts()
        drafts[mine[0].id].typed = "mine"
        drafts[theirs[0].id].typed = "theirs"

        drafts.keep(theirs)

        XCTAssertEqual(drafts[theirs[0].id].typed, "theirs")
        XCTAssertEqual(drafts[mine[0].id].typed, "")
        XCTAssertEqual(drafts.pages, [theirs[0].id])
    }

    /// Another session's question is still being asked while this one's card is
    /// up, so the prune has to be read against every ask the host is holding.
    func testAnotherSessionsAnswersAreNotPrunedByThisOnesCard() {
        let both = AskPages.read([ask("a1", ["Which?"]), ask("a2", key: "s2", ["Where?"])])

        var drafts = AskDrafts()
        for page in both { drafts[page.id].typed = page.id }

        drafts.keep(both)

        XCTAssertEqual(drafts.pages, Set(both.map(\.id)))
    }
}
