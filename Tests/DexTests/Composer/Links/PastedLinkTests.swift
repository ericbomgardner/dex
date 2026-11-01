import XCTest
@testable import DexCore

final class PastedLinkTests: XCTestCase {

    private func slack(_ url: String, file: StaticString = #filePath, line: UInt = #line) -> SlackLink? {
        guard case .slack(let link)? = PastedLink(url: url) else {
            XCTFail("not read as Slack: \(url)", file: file, line: line)
            return nil
        }
        return link
    }

    private func github(_ url: String, file: StaticString = #filePath, line: UInt = #line) -> GitHubLink? {
        guard case .github(let link)? = PastedLink(url: url) else {
            XCTFail("not read as GitHub: \(url)", file: file, line: line)
            return nil
        }
        return link
    }

    // What counts as a lone link

    func testSurroundingWhitespaceIsTrimmedAndKeptOutOfTheURL() {
        let link = PastedLink(pasted: "  https://github.com/acme/app/pull/12\n")
        XCTAssertEqual(link?.url, "https://github.com/acme/app/pull/12")
    }

    func testTextAroundTheLinkIsNotALoneLink() {
        XCTAssertNil(PastedLink(pasted: "see https://github.com/acme/app/pull/12"))
        XCTAssertNil(PastedLink(pasted: "https://github.com/acme/app/pull/12 https://github.com/acme/app/pull/13"))
        XCTAssertNil(PastedLink(pasted: "https://github.com/acme/app/pull/12\nand more"))
    }

    func testOtherURLsAndNonURLsAreLeftAsText() {
        XCTAssertNil(PastedLink(pasted: "https://example.com/acme/app/pull/12"))
        XCTAssertNil(PastedLink(pasted: "ftp://github.com/acme/app/pull/12"))
        XCTAssertNil(PastedLink(pasted: "github.com/acme/app/pull/12"))
        XCTAssertNil(PastedLink(pasted: "ENG-123"))
        XCTAssertNil(PastedLink(pasted: ""))
    }

    // GitHub

    func testAPullRequest() {
        let link = github("https://github.com/acme/app/pull/123")
        XCTAssertEqual(link?.owner, "acme")
        XCTAssertEqual(link?.repo, "app")
        XCTAssertEqual(link?.number, 123)
        XCTAssertEqual(link?.kind, .pull)
        XCTAssertEqual(PastedLink(url: "https://github.com/acme/app/pull/123")?.fallbackTitle, "acme/app#123")
    }

    func testAnIssue() {
        let link = github("https://github.com/acme/app/issues/7")
        XCTAssertEqual(link?.kind, .issue)
        XCTAssertEqual(link?.reference, "acme/app#7")
    }

    func testAPullRequestTabCommentOrQueryStillNamesThePullRequest() {
        for url in [
            "https://github.com/acme/app/pull/123/files",
            "https://github.com/acme/app/pull/123/files?w=1",
            "https://github.com/acme/app/pull/123#issuecomment-99",
            "https://github.com/acme/app/pull/123/commits/abc123",
            "https://www.github.com/acme/app/pull/123?notification_referrer_id=X",
        ] {
            XCTAssertEqual(github(url)?.reference, "acme/app#123", url)
            XCTAssertEqual(PastedLink(url: url)?.url, url, "the URL goes out as pasted")
        }
    }

    func testRepoNamesWithDotsAndDashes() {
        XCTAssertEqual(github("https://github.com/some-org/app.swift/issues/4")?.reference, "some-org/app.swift#4")
    }

    func testGitHubPagesThatAreNotAPullOrIssue() {
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app"))
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app/pulls"))
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app/issues"))
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app/issues/new"))
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app/pull/0"))
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app/discussions/5"))
        XCTAssertNil(PastedLink(url: "https://github.com/acme/app/blob/main/README.md"))
        XCTAssertNil(PastedLink(url: "https://gist.github.com/acme/abc/pull/1"))
    }

    // Slack

    func testAMessageOnAWorkspaceHost() {
        let link = slack("https://acme.slack.com/archives/C0123ABC/p1700000000123456")
        XCTAssertEqual(link?.channel, "C0123ABC")
        XCTAssertEqual(link?.ts, "1700000000.123456")
        XCTAssertNil(link?.threadTs)
        XCTAssertEqual(link?.kind, .message)
        XCTAssertEqual(link?.workspace, "acme")
        XCTAssertEqual(PastedLink(url: "https://acme.slack.com/archives/C0123ABC/p1700000000123456")?.fallbackTitle,
                       "Slack message in acme")
    }

    func testAReplyCarriesItsThreadInTheQuery() {
        let link = slack("https://acme.slack.com/archives/C0123ABC/p1700000500000200?thread_ts=1700000000.123456&cid=C0123ABC")
        XCTAssertEqual(link?.ts, "1700000500.000200")
        XCTAssertEqual(link?.threadTs, "1700000000.123456")
        XCTAssertEqual(link?.kind, .reply)
    }

    func testAThreadParentLinkedWithItsOwnThreadTsIsAMessage() {
        let link = slack("https://acme.slack.com/archives/C0123ABC/p1700000000123456?thread_ts=1700000000.123456&cid=C0123ABC")
        XCTAssertNil(link?.threadTs)
        XCTAssertEqual(link?.kind, .message)
    }

    func testAChannelOnAWorkspaceHost() {
        let link = slack("https://acme.slack.com/archives/C0123ABC")
        XCTAssertEqual(link?.kind, .channel)
        XCTAssertNil(link?.ts)
        XCTAssertEqual(PastedLink(url: "https://acme.slack.com/archives/C0123ABC")?.fallbackTitle, "Slack channel in acme")
    }

    func testAnEnterpriseGridHostNamesItsWorkspace() {
        XCTAssertEqual(slack("https://acme.enterprise.slack.com/archives/C0123ABC/p1700000000123456")?.workspace, "acme")
    }

    func testTheAppClientChannel() {
        let link = slack("https://app.slack.com/client/T0123/C0123ABC")
        XCTAssertEqual(link?.team, "T0123")
        XCTAssertEqual(link?.channel, "C0123ABC")
        XCTAssertEqual(link?.kind, .channel)
        XCTAssertNil(link?.workspace, "app.slack.com is not a workspace")
        XCTAssertEqual(PastedLink(url: "https://app.slack.com/client/T0123/C0123ABC")?.fallbackTitle, "Slack channel")
    }

    func testTheAppClientThreadView() {
        let link = slack("https://app.slack.com/client/T0123/C0123ABC/thread/C0123ABC-1700000000.123456")
        XCTAssertEqual(link?.channel, "C0123ABC")
        XCTAssertEqual(link?.threadTs, "1700000000.123456")
        XCTAssertEqual(link?.kind, .thread)
    }

    func testTheAppClientWithAQueryStillReadsTheChannel() {
        XCTAssertEqual(slack("https://app.slack.com/client/T0123/C0123ABC?cdn_fallback=2")?.kind, .channel)
    }

    func testDirectMessagesAndGroups() {
        XCTAssertEqual(slack("https://acme.slack.com/archives/D0123ABC/p1700000000123456")?.channel, "D0123ABC")
        XCTAssertEqual(slack("https://acme.slack.com/archives/G0123ABC")?.channel, "G0123ABC")
    }

    func testSlackPagesThatAreNotAMessageOrChannel() {
        XCTAssertNil(PastedLink(url: "https://acme.slack.com/"))
        XCTAssertNil(PastedLink(url: "https://acme.slack.com/archives/general"))
        XCTAssertNil(PastedLink(url: "https://acme.slack.com/archives/C0123ABC/notapermalink"))
        XCTAssertNil(PastedLink(url: "https://api.slack.com/methods/conversations.history"))
        XCTAssertNil(PastedLink(url: "https://notslack.com/archives/C0123ABC"))
    }

    // Linear

    func testALinearIssue() {
        guard case .linear(let link)? = PastedLink(url: "https://linear.app/acme/issue/ENG-123/fix-the-sidebar") else {
            return XCTFail()
        }
        XCTAssertEqual(link.identifier, "ENG-123")
        XCTAssertEqual(link.workspace, "acme")
        XCTAssertEqual(PastedLink(url: link.url)?.fallbackTitle, "ENG-123")
    }

    func testALinearIssueWithoutASlugOrWithAQuery() {
        XCTAssertEqual(PastedLink(url: "https://linear.app/acme/issue/eng-9")?.fallbackTitle, "ENG-9")
        XCTAssertEqual(PastedLink(url: "https://linear.app/acme/issue/ENG-9/x?comment=abc")?.fallbackTitle, "ENG-9")
    }

    func testLinearPagesThatAreNotAnIssue() {
        XCTAssertNil(PastedLink(url: "https://linear.app/acme/project/roadmap-abc123"))
        XCTAssertNil(PastedLink(url: "https://linear.app/acme/team/ENG/active"))
        XCTAssertNil(PastedLink(url: "https://linear.app/acme/issue/notanid"))
    }

    // Notion

    func testANotionPageWithASlug() {
        guard case .notion(let link)? = PastedLink(url: "https://www.notion.so/acme/Launch-Plan-0123456789abcdef0123456789abcdef") else {
            return XCTFail()
        }
        XCTAssertEqual(link.pageId, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(link.slug, "Launch Plan")
    }

    func testANotionPeekNamesThePageNotTheDatabase() {
        let url = "https://www.notion.so/acme/ffffffffffffffffffffffffffffffff?v=1&p=0123456789abcdef0123456789abcdef&pm=s"
        guard case .notion(let link)? = PastedLink(url: url) else { return XCTFail() }
        XCTAssertEqual(link.pageId, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(PastedLink(url: url)?.fallbackTitle, "Notion page")
    }

    func testANotionPageByBareIdOrDashedId() {
        XCTAssertEqual(PastedLink(url: "https://acme.notion.site/0123456789abcdef0123456789abcdef")?.service, .notion)
        guard case .notion(let link)? = PastedLink(url: "https://notion.so/Notes-01234567-89ab-cdef-0123-456789abcdef") else {
            return XCTFail()
        }
        XCTAssertEqual(link.pageId, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(link.slug, "Notes")
    }

    func testANotionURLWithoutAPageId() {
        XCTAssertNil(PastedLink(url: "https://www.notion.so/acme"))
    }
}
