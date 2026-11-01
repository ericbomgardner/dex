import XCTest
@testable import DexCore

final class LinkMentionTests: XCTestCase {

    private let pr = PastedLink(url: "https://github.com/acme/app/pull/12")!
    private let message = PastedLink(url: "https://acme.slack.com/archives/C0123ABC/p1700000000123456")!

    func testAnUnresolvedChipSaysWhatTheURLGivesAway() {
        let mention = LinkMention(pr)
        XCTAssertEqual(mention.title, "acme/app#12")
        XCTAssertFalse(mention.isResolved)
        XCTAssertEqual(mention.sentence, "[acme/app#12](https://github.com/acme/app/pull/12)")
    }

    func testAResolvedChipShowsTheTitleAndSendsTheURL() {
        let mention = LinkMention(pr, resolution: LinkResolution(title: "Fix the sidebar", detail: "PR acme/app#12 · merged", state: .merged))
        XCTAssertEqual(mention.title, "Fix the sidebar")
        XCTAssertEqual(mention.state, .merged)
        XCTAssertEqual(mention.sentence, "[Fix the sidebar](https://github.com/acme/app/pull/12)")
        XCTAssertEqual(mention.id, "https://github.com/acme/app/pull/12")
    }

    func testEachServiceGetsItsMention() {
        guard case .github(let github) = LinkMention(pr) else { return XCTFail() }
        XCTAssertEqual(github.link.number, 12)
        guard case .slack(let slack) = LinkMention(message) else { return XCTFail() }
        XCTAssertEqual(slack.title, "Slack message in acme")
        guard case .page(let page) = LinkMention(PastedLink(url: "https://linear.app/acme/issue/ENG-1")!) else { return XCTFail() }
        XCTAssertEqual(page.title, "ENG-1")
        XCTAssertEqual(LinkMention(PastedLink(url: "https://linear.app/acme/issue/ENG-1")!).service, .linear)
    }

    func testAPastedLinkChipSendsItsLinkInTheSentenceAndNothingUnder() {
        let chip = Mention.link(LinkMention(pr, resolution: LinkResolution(title: "Fix the sidebar", state: .merged)))
        let draft = ComposerChips.draft(from: [.text("see "), .chip(chip)])
        XCTAssertEqual(ComposerChips.chips(in: draft), [chip])
        XCTAssertEqual(ComposerAttachments.prompt(draft: draft, attachments: [],
                                                  mentions: ComposerChips.named(in: draft, known: [])),
                       "see [Fix the sidebar](https://github.com/acme/app/pull/12)")
        XCTAssertEqual(chip.source, .github)
        XCTAssertFalse(chip.isPending)
    }

    func testEachLinkChipIsMarkedWithItsService() {
        XCTAssertEqual(Mention.link(LinkMention(message)).source, .slack)
        XCTAssertEqual(Mention.link(LinkMention(PastedLink(url: "https://linear.app/acme/issue/ENG-1")!)).source,
                       .linearIssue)
        XCTAssertTrue(Mention.link(LinkMention(pr)).isPending)
    }

    func testALinearIssueSaysWhetherItIsFinished() {
        let issue = { (type: String) in
            LinearIssueMention(identifier: "ENG-1", title: "Fix login", url: "u", stateName: "", stateType: type)
        }
        XCTAssertEqual(issue("completed").resolution.state, .done)
        XCTAssertEqual(issue("canceled").resolution.state, .closed)
        XCTAssertNil(issue("started").resolution.state)
        XCTAssertEqual(issue("started").resolution.title, "Fix login")
        XCTAssertTrue(Mention.link(LinkMention(PastedLink(url: "https://linear.app/acme/issue/ENG-1")!,
                                               resolution: issue("canceled").resolution)).isClosed)
    }

    func testATitleWithBracketsCannotCloseTheLinkEarly() {
        XCTAssertEqual(LinkSentence.markdown(title: "[WIP] a]b\\c", url: "https://x.test"),
                       #"[\[WIP\] a\]b\\c](https://x.test)"#)
    }

    func testAMultilineTitleIsOneLine() {
        XCTAssertEqual(LinkSentence.markdown(title: "first\n\nsecond  line", url: "https://x.test"),
                       "[first second line](https://x.test)")
    }

    func testALongTitleIsShortened() {
        let title = String(repeating: "word ", count: 40)
        let sentence = LinkSentence.markdown(title: title, url: "https://x.test")
        let shown = sentence.dropFirst().prefix { $0 != "]" }
        XCTAssertEqual(shown.count, LinkSentence.longestTitle)
        XCTAssertTrue(shown.hasSuffix("…"))
    }

    func testParensInTheURLCannotEndTheLink() {
        XCTAssertEqual(LinkSentence.markdown(title: "t", url: "https://x.test/a_(b)"),
                       "[t](https://x.test/a_%28b%29)")
    }
}
