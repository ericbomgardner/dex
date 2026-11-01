import XCTest
@testable import DexCore

final class MarkdownTests: XCTestCase {

    private func paragraph(_ block: MarkdownBlock?) -> String? {
        guard case .paragraph(let text) = block else { return nil }
        return text
    }

    private func items(_ block: MarkdownBlock?) -> [MarkdownListItem]? {
        guard case .list(let items) = block else { return nil }
        return items
    }

    private func table(_ block: MarkdownBlock?) -> MarkdownTable? {
        guard case .table(let table) = block else { return nil }
        return table
    }

    // Paragraphs

    func testABlankLineStartsANewParagraph() {
        let blocks = Markdown.blocks(in: "first thing\n\nsecond thing")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(paragraph(blocks.first), "first thing")
        XCTAssertEqual(paragraph(blocks.last), "second thing")
    }

    /// Whoever wrote it wrapped to a width, and it is not the one this is being
    /// read at — a plan written for an 80-column terminal came out as three
    /// short lines per paragraph in a card half again as wide.
    func testAWrappedParagraphRunsBackTogether() {
        XCTAssertEqual(paragraph(Markdown.blocks(in: "one\ntwo").first), "one two")
    }

    func testTwoTrailingSpacesKeepTheBreak() {
        XCTAssertEqual(paragraph(Markdown.blocks(in: "one  \ntwo").first), "one\ntwo")
    }

    func testATrailingBackslashKeepsTheBreakWithoutPrintingItself() {
        XCTAssertEqual(paragraph(Markdown.blocks(in: "one\\\ntwo").first), "one\ntwo")
    }

    /// The break falls mid-span, so joining it wrong would leave a stray newline
    /// inside the backticks for the view to lay out.
    func testAWrapInsideInlineCodeStillReadsAsOneSpan() {
        XCTAssertEqual(
            paragraph(Markdown.blocks(in: "run `swift\nbuild` now").first),
            "run `swift build` now"
        )
    }

    func testIndentedWrappingIsNotKeptAsSpaces() {
        XCTAssertEqual(paragraph(Markdown.blocks(in: "one\n     two").first), "one two")
    }

    /// A plan as one is actually written — wrapped for a terminal, read in a
    /// card — with the blank line between the blocks still doing its job and the
    /// fence in the middle keeping every break it was given.
    func testAPlanWrappedForATerminalComesBackWhole() {
        let source = """
            The plan card landed and reads well, but the plans in it come out
            ragged. A plan file is written wrapped to about 80 columns.

            - `takeParagraph` joins a paragraph's lines with a newline, so the
              breaks survive into the card.
            - `takeQuote` does the same for blockquotes.

            ```swift
            let a = 1
            let b = 2
            ```
            """
        let blocks = Markdown.blocks(in: source)

        XCTAssertEqual(
            paragraph(blocks.first),
            "The plan card landed and reads well, but the plans in it come out ragged. "
                + "A plan file is written wrapped to about 80 columns."
        )
        XCTAssertEqual(items(blocks[1])?.map(\.text), [
            "`takeParagraph` joins a paragraph's lines with a newline, so the breaks survive into the card.",
            "`takeQuote` does the same for blockquotes.",
        ])
        XCTAssertEqual(blocks.last, .code(language: "swift", text: "let a = 1\nlet b = 2"))
    }

    func testInlineMarkupIsLeftAlone() {
        let text = "call `swift build` and read **the output**"
        XCTAssertEqual(paragraph(Markdown.blocks(in: text).first), text)
    }

    func testTrailingBlankLinesProduceNothing() {
        XCTAssertEqual(Markdown.blocks(in: "done\n\n\n").count, 1)
    }

    // Headings

    func testHeadingsCarryTheirLevel() {
        let blocks = Markdown.blocks(in: "# One\n## Two\n#### Four")
        XCTAssertEqual(blocks, [
            .heading(level: 1, text: "One"),
            .heading(level: 2, text: "Two"),
            .heading(level: 4, text: "Four"),
        ])
    }

    func testAClosingRunOfHashesIsNotPartOfTheHeading() {
        XCTAssertEqual(Markdown.blocks(in: "## Two ##"), [.heading(level: 2, text: "Two")])
    }

    func testAHashWithoutASpaceIsProse() {
        XCTAssertEqual(paragraph(Markdown.blocks(in: "#1 on the list").first), "#1 on the list")
    }

    func testAHeadingEndsTheParagraphAboveIt() {
        let blocks = Markdown.blocks(in: "intro\n## Next")
        XCTAssertEqual(paragraph(blocks.first), "intro")
        XCTAssertEqual(blocks.last, .heading(level: 2, text: "Next"))
    }

    // Rules

    func testThreeMarksMakeARule() {
        XCTAssertEqual(Markdown.blocks(in: "---"), [.rule])
        XCTAssertEqual(Markdown.blocks(in: "***"), [.rule])
        XCTAssertEqual(Markdown.blocks(in: "- - -"), [.rule])
    }

    func testABulletIsNotARule() {
        XCTAssertNotNil(items(Markdown.blocks(in: "- one").first))
    }

    // Lists

    func testBulletsBecomeOneList() {
        let list = items(Markdown.blocks(in: "- one\n- two\n- three").first)
        XCTAssertEqual(list?.count, 3)
        XCTAssertEqual(list?.map(\.text), ["one", "two", "three"])
        XCTAssertEqual(list?.map(\.marker), [nil, nil, nil])
    }

    func testACodeBlockIndentedUnderAnItemStaysACodeBlock() {
        let text = """
            1. Open a terminal.
            2. Clone the project and build it:
               ```
               git clone https://example.com/notes.git
               cd notes
               make && make test
               ```
            3. Open the built app.
            """
        XCTAssertEqual(Markdown.blocks(in: text), [
            .list([
                MarkdownListItem(level: 0, marker: "1.", text: "Open a terminal."),
                MarkdownListItem(level: 0, marker: "2.", text: "Clone the project and build it:"),
            ]),
            .nested(depth: 1, .code(language: nil, text: """
                git clone https://example.com/notes.git
                cd notes
                make && make test
                """)),
            .list([MarkdownListItem(level: 0, marker: "3.", text: "Open the built app.")]),
        ])
    }

    func testInlineCodeStartingAContinuationLineIsNoFence() {
        let blocks = Markdown.blocks(in: "- Build it\n  ```swift build``` should pass\n\nMore prose.")
        XCTAssertEqual(blocks, [
            .list([MarkdownListItem(level: 0, marker: nil, text: "Build it ```swift build``` should pass")]),
            .paragraph("More prose."),
        ])
    }

    func testASecondParagraphStaysInsideItsItem() {
        let text = """
            1. **Plan mode.** Read-only until you approve.

               It also keeps the plan on file.
            2. **Auto mode.** Runs without asking.

            After the list.
            """
        XCTAssertEqual(Markdown.blocks(in: text), [
            .list([MarkdownListItem(level: 0, marker: "1.", text: "**Plan mode.** Read-only until you approve.")]),
            .nested(depth: 1, .paragraph("It also keeps the plan on file.")),
            .list([MarkdownListItem(level: 0, marker: "2.", text: "**Auto mode.** Runs without asking.")]),
            .paragraph("After the list."),
        ])
    }

    func testAQuoteInsideAnItemStaysInsideIt() {
        let text = """
            2. **Fix the rule.** What's there now is narrow:

               > Don't hardcode values.
            3. Then the next thing.
            """
        XCTAssertEqual(Markdown.blocks(in: text), [
            .list([MarkdownListItem(level: 0, marker: "2.", text: "**Fix the rule.** What's there now is narrow:")]),
            .nested(depth: 1, .quote([.paragraph("Don't hardcode values.")])),
            .list([MarkdownListItem(level: 0, marker: "3.", text: "Then the next thing.")]),
        ])
    }

    func testANestedItemKeepsItsOwnCode() {
        let text = """
            - outer
              - inner
                ```
                make
                ```
            - next
            """
        XCTAssertEqual(Markdown.blocks(in: text), [
            .list([
                MarkdownListItem(level: 0, marker: nil, text: "outer"),
                MarkdownListItem(level: 1, marker: nil, text: "inner"),
            ]),
            .nested(depth: 2, .code(language: nil, text: "make")),
            .list([MarkdownListItem(level: 0, marker: nil, text: "next")]),
        ])
    }

    func testABulletInsideAnItemsCodeIsCode() {
        let text = "- run:\n  ```\n  - not an item\n  ```\n- next"
        XCTAssertEqual(Markdown.blocks(in: text), [
            .list([MarkdownListItem(level: 0, marker: nil, text: "run:")]),
            .nested(depth: 1, .code(language: nil, text: "- not an item")),
            .list([MarkdownListItem(level: 0, marker: nil, text: "next")]),
        ])
    }

    func testAListAndCodeInsideAQuote() {
        let text = "> You said:\n>\n> 1. first\n> 2. second\n>\n> ```\n> swift test\n> ```"
        XCTAssertEqual(Markdown.blocks(in: text), [
            .quote([
                .paragraph("You said:"),
                .list([
                    MarkdownListItem(level: 0, marker: "1.", text: "first"),
                    MarkdownListItem(level: 0, marker: "2.", text: "second"),
                ]),
                .code(language: nil, text: "swift test"),
            ]),
        ])
    }

    func testAnUnindentedParagraphAfterABlankLineEndsTheList() {
        XCTAssertEqual(Markdown.blocks(in: "- one\n\nafter"), [
            .list([MarkdownListItem(level: 0, marker: nil, text: "one")]),
            .paragraph("after"),
        ])
    }

    func testAParentsCodeAfterItsSubItemStaysWithTheParent() {
        let text = "1. Install\n   - run x\n\n   ```bash\n   cmd\n   ```\n\n   More about step one.\n2. Next"
        XCTAssertEqual(Markdown.blocks(in: text), [
            .list([
                MarkdownListItem(level: 0, marker: "1.", text: "Install"),
                MarkdownListItem(level: 1, marker: nil, text: "run x"),
            ]),
            .nested(depth: 1, .code(language: "bash", text: "cmd")),
            .nested(depth: 1, .paragraph("More about step one.")),
            .list([MarkdownListItem(level: 0, marker: "2.", text: "Next")]),
        ])
    }

    func testARunOfQuoteMarksStopsNesting() {
        let blocks = Markdown.blocks(in: String(repeating: ">", count: 5_000) + " deep")
        var depth = 0
        var block = blocks.first
        while case .quote(let inner) = block {
            depth += 1
            block = inner.first
        }
        XCTAssertEqual(depth, 8)
        guard case .paragraph(let rest) = block else { return XCTFail("\(String(describing: block))") }
        XCTAssertTrue(rest.hasSuffix("> deep"))
    }

    func testNumberedItemsKeepTheirMarker() {
        let list = items(Markdown.blocks(in: "1. first\n2) second").first)
        XCTAssertEqual(list?.map(\.marker), ["1.", "2."])
        XCTAssertEqual(list?.map(\.text), ["first", "second"])
    }

    func testIndentationBecomesNesting() {
        let list = items(Markdown.blocks(in: "- top\n  - under\n    - deeper\n- back").first)
        XCTAssertEqual(list?.map(\.level), [0, 1, 2, 0])
    }

    func testAWrappedItemKeepsItsOwnRow() {
        let list = items(Markdown.blocks(in: "- one\n  still one\n- two").first)
        XCTAssertEqual(list?.count, 2)
        XCTAssertEqual(list?.first?.text, "one still one")
    }

    /// The marker is stripped before the line is kept, so the spaces that ask
    /// for the break have to survive that.
    func testAnItemCanKeepABreakOfItsOwn() {
        let list = items(Markdown.blocks(in: "- one  \n  still one").first)
        XCTAssertEqual(list?.first?.text, "one\nstill one")
    }

    func testABlankLineBetweenItemsDoesNotEndTheList() {
        let list = items(Markdown.blocks(in: "- one\n\n- two").first)
        XCTAssertEqual(list?.count, 2)
    }

    func testProseAfterAListIsItsOwnParagraph() {
        let blocks = Markdown.blocks(in: "- one\n\nafter")
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(paragraph(blocks.last), "after")
    }

    func testAListStartsEvenWithoutABlankLineAboveIt() {
        let blocks = Markdown.blocks(in: "here they are:\n- one\n- two")
        XCTAssertEqual(paragraph(blocks.first), "here they are:")
        XCTAssertEqual(items(blocks.last)?.count, 2)
    }

    // Code

    func testAFenceCapturesItsLanguageAndBody() {
        let blocks = Markdown.blocks(in: "```swift\nlet a = 1\n\nlet b = 2\n```")
        XCTAssertEqual(blocks, [.code(language: "swift", text: "let a = 1\n\nlet b = 2")])
    }

    func testAFenceWithoutALanguageStillParses() {
        XCTAssertEqual(Markdown.blocks(in: "```\nplain\n```"), [.code(language: nil, text: "plain")])
    }

    func testAnUnclosedFenceRunsToTheEnd() {
        XCTAssertEqual(Markdown.blocks(in: "```\nstill going"), [.code(language: nil, text: "still going")])
    }

    func testMarkupInsideAFenceIsNotParsed() {
        let blocks = Markdown.blocks(in: "```\n# not a heading\n- not a list\n```")
        XCTAssertEqual(blocks, [.code(language: nil, text: "# not a heading\n- not a list")])
    }

    func testAnIndentedFenceLosesItsIndent() {
        let blocks = Markdown.blocks(in: "  ```\n  body\n  ```")
        XCTAssertEqual(blocks, [.code(language: nil, text: "body")])
    }

    // Quotes

    func testQuotedLinesJoinIntoOneBlock() {
        XCTAssertEqual(Markdown.blocks(in: "> one\n> two"), [.quote([.paragraph("one two")])])
    }

    func testABlankQuotedLineStartsAParagraphInsideTheQuote() {
        XCTAssertEqual(Markdown.blocks(in: "> one\n>\n> two"), [.quote([.paragraph("one"), .paragraph("two")])])
    }

    /// The `>` is found by trimming the line, which would take the two spaces
    /// asking for the break with it — so a quote would join what a paragraph
    /// spelt the same way keeps apart.
    func testAQuoteKeepsAHardBreakTheSameWayProseDoes() {
        XCTAssertEqual(Markdown.blocks(in: "> one  \n> two"), [.quote([.paragraph("one\ntwo")])])
        XCTAssertEqual(Markdown.blocks(in: "> one\\\n> two"), [.quote([.paragraph("one\ntwo")])])
    }

    func testAQuoteEndsAtUnquotedProse() {
        let blocks = Markdown.blocks(in: "> quoted\nplain")
        XCTAssertEqual(blocks.first, .quote([.paragraph("quoted")]))
        XCTAssertEqual(paragraph(blocks.last), "plain")
    }

    // Tables

    func testATableKeepsItsHeaderAndRows() {
        let source = """
        | Tool | Count |
        | --- | --- |
        | Bash | 9 |
        | Read | 2 |
        """
        let parsed = table(Markdown.blocks(in: source).first)
        XCTAssertEqual(parsed?.header, ["Tool", "Count"])
        XCTAssertEqual(parsed?.rows, [["Bash", "9"], ["Read", "2"]])
    }

    func testTheDividerRowSetsColumnAlignment() {
        let source = "| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |"
        XCTAssertEqual(table(Markdown.blocks(in: source).first)?.alignments, [.leading, .center, .trailing])
    }

    func testARaggedRowIsPaddedToTheHeaderWidth() {
        let source = "| a | b |\n| --- | --- |\n| 1 |"
        XCTAssertEqual(table(Markdown.blocks(in: source).first)?.rows, [["1", ""]])
    }

    func testPipesWithoutADividerRowAreJustProse() {
        let source = "| a | b |\n| 1 | 2 |"
        XCTAssertNil(table(Markdown.blocks(in: source).first))
    }

    func testATableStartsEvenRightAfterAParagraph() {
        let source = "results:\n| a |\n| --- |\n| 1 |"
        let blocks = Markdown.blocks(in: source)
        XCTAssertEqual(paragraph(blocks.first), "results:")
        XCTAssertEqual(table(blocks.last)?.rows, [["1"]])
    }
}
