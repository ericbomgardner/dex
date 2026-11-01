import AppKit
import XCTest
@testable import DexUI
@testable import DexCore

@MainActor
final class SelectionMarkdownTests: XCTestCase {

    private func drawn(_ markdown: String) -> NSAttributedString {
        ProseMarkup.attributed(.markdown(Markdown.blocks(in: markdown)), face: ProseFace())
    }

    private func copied(_ markdown: String) -> String {
        SelectionMarkdown.fragment(drawn(markdown))
    }

    func testAReplyComesBackAsTheMarkdownItWasDrawnFrom() {
        let source = """
            ## Next steps

            Run **both** builds, then `swift test`. See [the doc](https://example.com/x).

            - one
              - nested *a*
              - nested b
            - two

            1. first
            2. second
            """
        XCTAssertEqual(copied(source), source)
    }

    func testHeadingLevelsComeBack() {
        XCTAssertEqual(copied("# One\n\n## Two\n\n### Three"), "# One\n\n## Two\n\n### Three")
    }

    func testAParagraphInBoldIsNotAHeading() {
        XCTAssertEqual(copied("**All of this is bold.**"), "**All of this is bold.**")
    }

    func testMarksStayAgainstTheTextTheyWrap() {
        XCTAssertEqual(copied("a **b** c"), "a **b** c")
        XCTAssertEqual(copied("use `` a`b `` here"), "use ``a`b`` here")
    }

    func testASelectionStartingInsideTheBulletStillReadsAsAnItem() {
        let whole = drawn("- one\n- two")
        let string = whole.string as NSString
        let from = string.range(of: "•\ttwo").location
        let piece = whole.attributedSubstring(from: NSRange(location: from, length: string.length - from))
        XCTAssertEqual(SelectionMarkdown.fragment(piece), "- two")
    }

    func testCodeIsFencedPastAnyFenceInsideIt() {
        XCTAssertEqual(SelectionMarkdown.fenced("swift build\nswift test"), "```\nswift build\nswift test\n```")
        XCTAssertEqual(SelectionMarkdown.fenced("a\n```\nb"), "````\na\n```\nb\n````")
    }

    func testAHeadingKeepsItsCodeSpan() {
        XCTAssertEqual(copied("## The `selectedText()` path"), "## The `selectedText()` path")
    }

    func testASemiboldParagraphThatIsNoHeadingStaysProse() {
        let header = ProseMarkup.attributed(.markdown([.paragraph("Name")]), face: ProseFace(weight: .semibold))
        XCTAssertEqual(SelectionMarkdown.fragment(header), "Name")
    }

    func testTextThatWasNeverMarkdownCopiesAsItsCharacters() {
        let thought = ProseView()
        thought.show(.plain("first line\n\nsecond *line*"), face: ProseFace(size: 13, italic: true))
        let all = 0..<thought.selectionLength
        XCTAssertEqual(thought.selectionMarkdown(in: all, alone: true), "first line\n\nsecond *line*")
        XCTAssertEqual(thought.selectionMarkdown(in: all, alone: false), "first line\n\nsecond *line*")
    }

    func testASecondParagraphIsCopiedInsideItsItem() {
        let source = "1. first\n\n   more about first\n2. second"
        XCTAssertEqual(copied(source), source)
        let wide = "10. step\n\n    more about the step\n11. next"
        XCTAssertEqual(copied(wide), wide)
        XCTAssertEqual(Markdown.blocks(in: copied(wide)), Markdown.blocks(in: wide))
    }

    func testAQuotedRunIsCopiedWithItsMarks() {
        let quote = ProseView()
        var face = ProseFace(tint: .secondary)
        face.quoted = 1
        quote.show(.markdown(Markdown.blocks(in: "You said:\n\n- this")), face: face)
        let all = 0..<quote.selectionLength
        XCTAssertEqual(quote.selectionMarkdown(in: all, alone: false), "> You said:\n>\n> - this")
        XCTAssertEqual(quote.selectionHTML(in: all), "<blockquote><p>You said:</p>\n<ul><li>this</li></ul></blockquote>")
    }

    func testAHeadingInsideAnItemKeepsItsMarks() {
        XCTAssertEqual(copied("- a\n\n  ## Sub"), "- a\n\n  ## Sub")
    }

    func testANestedListUnderAWideMarkerStaysNested() {
        let source = "10. step\n    - inner"
        XCTAssertEqual(copied(source), source)
    }
}
