import XCTest

@testable import DexCore

private func question(_ text: String, header: String = "Scope") -> JSONValue {
    .object([
        "question": .string(text),
        "header": .string(header),
        "options": .array([
            .object(["label": .string("One"), "description": .string("the first")]),
            .object(["label": .string("Two"), "description": .string("the second")]),
        ]),
    ])
}

private func questions(_ id: String, key: String = "s1", _ texts: [String]) -> HostAsk {
    HostAsk(
        askId: id,
        key: key,
        kind: .question,
        toolName: "AskUserQuestion",
        input: .object(["questions": .array(texts.map { question($0) })]),
        options: []
    )
}

private func permission(_ id: String, key: String = "s1") -> HostAsk {
    HostAsk(
        askId: id,
        key: key,
        kind: .permission,
        toolName: "Bash",
        input: .object(["command": .string("npm test")]),
        options: [HostAskOption(optionId: "allow_once", name: "Allow", kind: .allowOnce)]
    )
}

final class AskPagesTests: XCTestCase {

    func testEveryQuestionOfEveryAskIsItsOwnPage() {
        let pages = AskPages.read([
            questions("a", ["Which layout?", "How dense?"]),
            questions("b", ["Ship when?"]),
        ])

        XCTAssertEqual(pages.count, 3)
        XCTAssertEqual(
            pages.map { $0.question?.question },
            ["Which layout?", "How dense?", "Ship when?"]
        )
        XCTAssertEqual(pages.map(\.askId), ["a", "a", "b"])
    }

    /// A permission has nothing to page through, and answers on its own buttons
    /// rather than waiting for the send — but it is still somewhere in the run.
    func testAPermissionIsOnePage() {
        let pages = AskPages.read([permission("p"), questions("a", ["Which layout?"])])

        XCTAssertEqual(pages.count, 2)
        XCTAssertNil(pages[0].question)
        XCTAssertEqual(pages[0].permission?.toolName, "Bash")
        XCTAssertEqual(pages[1].question?.question, "Which layout?")
    }

    /// Two asks can word a question the same way, and an answer filed under the
    /// text alone would be read as belonging to both.
    func testTheSameQuestionInTwoAsksIsTwoPages() {
        let pages = AskPages.read([
            questions("a", ["Ship when?"]),
            questions("b", ["Ship when?"]),
        ])

        XCTAssertEqual(pages.count, 2)
        XCTAssertNotEqual(pages[0].id, pages[1].id)
    }

    func testAQuestionWithNoOptionsLeavesNoPageBehind() {
        let ask = HostAsk(
            askId: "a",
            key: "s1",
            kind: .question,
            toolName: "AskUserQuestion",
            input: .object([
                "questions": .array([
                    .object(["question": .string("Unanswerable"), "options": .array([])]),
                    question("Which layout?"),
                ])
            ]),
            options: []
        )

        XCTAssertEqual(AskPages.read([ask]).map { $0.question?.question }, ["Which layout?"])
    }

    func testNothingPendingIsNoPages() {
        XCTAssertTrue(AskPages.read([]).isEmpty)
    }

    /// What the composer answers is the question in front of you, so the page
    /// being read has to name the ask it belongs to and not the oldest one.
    func testAPageNamesTheAskItCameFrom() {
        let asks = [questions("a", ["Which layout?", "How dense?"]), questions("b", ["Ship when?"])]
        let pages = AskPages.read(asks)

        XCTAssertEqual(AskPages.owner(of: pages[2].id, in: asks)?.askId, "b")
        XCTAssertEqual(AskPages.owner(of: pages[1].id, in: asks)?.askId, "a")
        XCTAssertNil(AskPages.owner(of: "no such page", in: asks))
    }

    func testAPermissionPageNamesItsAskToo() {
        let asks = [questions("a", ["Which layout?"]), permission("p")]
        let pages = AskPages.read(asks)

        XCTAssertEqual(AskPages.owner(of: pages[1].id, in: asks)?.askId, "p")
    }
}
