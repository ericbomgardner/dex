import AppKit
import XCTest
@testable import DexUI
@testable import DexCore

@MainActor
final class SelectionHTMLTests: XCTestCase {

    private func html(_ markdown: String) -> String {
        SelectionHTML.fragment(ProseMarkup.attributed(.markdown(Markdown.blocks(in: markdown)), face: ProseFace()))
    }

    func testInlineMarkupBecomesTags() {
        let out = html("Use **bold**, *italic*, `code`, ~~gone~~ and [a link](https://example.com/x).")
        XCTAssertTrue(out.contains("<b>bold</b>"), out)
        XCTAssertTrue(out.contains("<i>italic</i>"), out)
        XCTAssertTrue(out.contains("<code>code</code>"), out)
        XCTAssertTrue(out.contains("<s>gone</s>"), out)
        XCTAssertTrue(out.contains("<a href=\"https://example.com/x\">a link</a>"), out)
        XCTAssertTrue(out.hasPrefix("<p>") && out.hasSuffix("</p>"), out)
    }

    func testParagraphsAndHeadingsKeepTheirBreaks() {
        let out = html("## Reading\n\nFirst paragraph.\n\nSecond paragraph.")
        XCTAssertEqual(out.components(separatedBy: "<p>").count - 1, 3, out)
        XCTAssertTrue(out.contains("<p><b>Reading</b></p>"), out)
        XCTAssertTrue(out.contains("<p>First paragraph.</p>\n<p>Second paragraph.</p>"), out)
    }

    func testListsBecomeListsWithTheMarkersDropped() {
        let out = html("- one\n- two\n\n1. first\n2. second")
        XCTAssertTrue(out.contains("<ul><li>one</li><li>two</li></ul>"), out)
        XCTAssertTrue(out.contains("<ol><li>first</li><li>second</li></ol>"), out)
        XCTAssertFalse(out.contains("•"), out)
        XCTAssertFalse(out.contains("\t"), out)
    }

    func testNestedListsKeepTheirNesting() {
        let out = html("- top one\n  - nested a\n  - nested b\n- top two")
        XCTAssertEqual(out, "<ul><li>top one<ul><li>nested a</li><li>nested b</li></ul></li><li>top two</li></ul>")
    }

    func testASelectionStartingInsideTheBulletStillReadsAsAnItem() {
        let whole = ProseMarkup.attributed(.markdown(Markdown.blocks(in: "- one\n- two")), face: ProseFace())
        let string = whole.string as NSString
        let secondTab = string.range(of: "\ttwo").location
        let piece = whole.attributedSubstring(from: NSRange(location: secondTab, length: string.length - secondTab))
        XCTAssertEqual(SelectionHTML.fragment(piece), "<ul><li>two</li></ul>")
        let afterBullet = string.range(of: "•\ttwo").location
        let fromBullet = whole.attributedSubstring(from: NSRange(location: afterBullet, length: string.length - afterBullet))
        XCTAssertEqual(SelectionHTML.fragment(fromBullet), "<ul><li>two</li></ul>")
    }

    func testTextIsEscaped() {
        XCTAssertEqual(html("a < b & c > d"), "<p>a &lt; b &amp; c &gt; d</p>")
        XCTAssertEqual(SelectionHTML.fragment(plain: "x < y\nz"), "<p>x &lt; y<br>z</p>")
        XCTAssertEqual(SelectionHTML.preformatted("swift build\nswift test"), "<pre>swift build\nswift test</pre>")
    }

    func testAPartialRangeInsideAParagraphStillFormats() {
        let whole = ProseMarkup.attributed(.markdown(Markdown.blocks(in: "Plain then **bold** then plain.")), face: ProseFace())
        let start = (whole.string as NSString).range(of: "then bold").location
        let piece = whole.attributedSubstring(from: NSRange(location: start, length: 9))
        XCTAssertEqual(SelectionHTML.fragment(piece), "<p>then <b>bold</b></p>")
    }

    func testEmptySelectionIsNothing() {
        XCTAssertEqual(SelectionHTML.fragment(plain: ""), "")
        XCTAssertEqual(SelectionHTML.fragment(NSAttributedString()), "")
    }

    func testDocumentWrapsFragments() {
        let out = SelectionHTML.document(["<p>a</p>", "<pre>b</pre>"])
        XCTAssertTrue(out.hasPrefix("<!doctype html>"), out)
        XCTAssertTrue(out.contains("<p>a</p>\n<pre>b</pre>"), out)
        XCTAssertTrue(out.hasSuffix("</body></html>"), out)
    }

    func testANumberedListPickedUpAfterABlockKeepsItsNumber() {
        XCTAssertEqual(html("3. third\n4. fourth"), "<ol start=\"3\"><li>third</li><li>fourth</li></ol>")
    }
}
