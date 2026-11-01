import XCTest
@testable import DexCore

func linkedFixture(_ name: String) throws -> Data {
    let url = try XCTUnwrap(
        Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures")
            ?? Bundle.module.url(forResource: name, withExtension: "json"))
    return try Data(contentsOf: url)
}

final class LinearIssueMentionTests: XCTestCase {

    func testRecentPutsMyOpenIssuesFirstOnceEachAndDropsUntitled() throws {
        let issues = try LinearIssues.parseRecent(linkedFixture("linear-recent"))
        XCTAssertEqual(issues.map(\.identifier), ["ENG-412", "ENG-398", "DES-77"])
    }

    func testDetailIsIdentifierStateAndTeam() throws {
        let issue = try XCTUnwrap(LinearIssues.parseRecent(linkedFixture("linear-recent")).first)
        XCTAssertEqual(issue.detail, "ENG-412 · In Progress · Engineering")
        XCTAssertFalse(issue.isClosed)
    }

    func testLineNamesTheIdentifierAndURL() throws {
        let issue = try XCTUnwrap(LinearIssues.parseIssue(linkedFixture("linear-issue")))
        XCTAssertEqual(issue.line,
                       "@Crash when the socket drops mid-turn refers to Linear issue ENG-123 (https://linear.app/acme/issue/ENG-123/crash-when-the-socket-drops-mid-turn)")
        XCTAssertTrue(issue.isClosed)
    }

    func testLineWithoutURLLeavesOffTheParentheses() {
        let issue = LinearIssueMention(identifier: "ENG-1", title: "x", url: "", stateName: "", stateType: "")
        XCTAssertEqual(issue.line, "@x refers to Linear issue ENG-1")
    }

    func testSearchReadsTheIssuesConnection() throws {
        let issues = try LinearIssues.parseSearch(linkedFixture("linear-search"))
        XCTAssertEqual(issues.map(\.identifier), ["ENG-412", "OPS-9"])
        XCTAssertEqual(issues.last?.detail, "OPS-9 · Done · Operations")
    }

    func testAMissingIssueIsNilNotAFailure() throws {
        XCTAssertNil(try LinearIssues.parseIssue(linkedFixture("linear-not-found")))
    }

    func testAnUnauthenticatedReplyIsTheKey() throws {
        let data = try linkedFixture("linear-unauthenticated")
        XCTAssertThrowsError(try LinearIssues.parseSearch(data)) {
            XCTAssertEqual($0 as? LinkedServiceError, .unauthorized)
        }
        XCTAssertThrowsError(try LinearIssues.parseIssue(data)) {
            XCTAssertEqual($0 as? LinkedServiceError, .unauthorized)
        }
    }

    func testGarbageIsUnreadable() {
        XCTAssertThrowsError(try LinearIssues.parseSearch(Data("<html>".utf8))) {
            XCTAssertEqual($0 as? LinkedServiceError, .unreadable)
        }
    }

    func testViewerName() throws {
        let data = Data(#"{"data":{"viewer":{"name":"Ada Example","email":"e@example.com"}}}"#.utf8)
        XCTAssertEqual(try LinearIssues.parseViewer(data), "Ada Example")
    }

    func testIdentifiers() {
        XCTAssertEqual(LinearIssues.identifier(in: " eng-123 "), "ENG-123")
        XCTAssertEqual(LinearIssues.identifier(in: "A2-9"), "A2-9")
        XCTAssertNil(LinearIssues.identifier(in: "ENG-"))
        XCTAssertNil(LinearIssues.identifier(in: "fix ENG-12"))
        XCTAssertNil(LinearIssues.identifier(in: "123"))
    }

    func testIdentifierFromURLSkipsAWorkspaceSlugThatLooksLikeOne() {
        XCTAssertEqual(LinearIssues.identifier(fromURL: "https://linear.app/acme-2/issue/eng-5/fix-it"), "ENG-5")
        XCTAssertEqual(LinearIssues.identifier(fromURL: "https://linear.app/acme/issue/ENG-5"), "ENG-5")
        XCTAssertNil(LinearIssues.identifier(fromURL: "https://linear.app/acme-2/project/foo"))
        XCTAssertNil(LinearIssues.identifier(fromURL: "https://example.com/issue/ENG-5"))
        XCTAssertNil(LinearIssues.identifier(fromURL: "ENG-5"))
    }

    func testTheKeyGoesInBare() {
        let request = LinearIssues.request(LinearIssues.viewerBody(), key: "lin_api_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "lin_api_test")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, LinearIssues.endpoint)
    }

    func testSearchTextTravelsAsAVariableWordByWord() throws {
        let body = try JSONSerialization.jsonObject(with: LinearIssues.searchBody(for: #"fix "login""#)) as? [String: Any]
        let query = try XCTUnwrap(body?["query"] as? String)
        XCTAssertFalse(query.contains("login"))
        let filter = (body?["variables"] as? [String: Any])?["filter"] as? [String: Any]
        let words = (filter?["and"] as? [[String: Any]])?.compactMap {
            ($0["title"] as? [String: Any])?["containsIgnoreCase"] as? String
        }
        XCTAssertEqual(words, ["fix", #""login""#])
    }

    func testABareNumberAlsoMatchesTheIssueNumber() throws {
        let body = try JSONSerialization.jsonObject(with: LinearIssues.searchBody(for: "42")) as? [String: Any]
        let filter = (body?["variables"] as? [String: Any])?["filter"] as? [String: Any]
        let either = try XCTUnwrap(filter?["or"] as? [[String: Any]])
        XCTAssertEqual((either.last?["number"] as? [String: Any])?["eq"] as? Int, 42)
    }
}

final class NotionPageMentionTests: XCTestCase {

    func testSearchReadsPagesWithTitleEmojiAndParent() throws {
        let pages = try NotionPages.parseSearch(linkedFixture("notion-search"))
        XCTAssertEqual(pages.map(\.title), ["Q4 launch plan", "Webhook retries", "Roadmap", "Untitled"])
        XCTAssertEqual(pages[0].pageID, "598337872cf94fdf8782e53db20768a5")
        XCTAssertEqual(pages[0].emoji, "🚀")
        XCTAssertNil(pages[1].emoji)
        XCTAssertEqual(pages[0].parent, .page("1a2b3c4d5e6f4a1b8c2d3e4f5a6b7c8d"))
        XCTAssertEqual(pages[1].parent, .database("d9824bdc84454327be8b5b47500af6ce"))
        XCTAssertEqual(pages[2].parent, .workspace)
        XCTAssertEqual(pages[3].parent, .unknown)
    }

    func testDetailIsEmojiAndWhereItSits() throws {
        var pages = try NotionPages.parseSearch(linkedFixture("notion-search"))
        XCTAssertEqual(pages[0].detail, "🚀")
        pages[0].parentTitle = "Roadmap"
        XCTAssertEqual(pages[0].detail, "🚀 Roadmap")
        XCTAssertEqual(pages[2].detail, "Workspace")
        XCTAssertEqual(pages[3].detail, "")
    }

    func testLineNamesTheURL() throws {
        let page = try XCTUnwrap(NotionPages.parsePage(linkedFixture("notion-page")))
        XCTAssertEqual(page.line,
                       "@Q4 launch plan refers to Notion page https://www.notion.so/Q4-launch-plan-598337872cf94fdf8782e53db20768a5")
    }

    func testAPageTheIntegrationCantSeeIsNil() throws {
        XCTAssertNil(try NotionPages.parsePage(linkedFixture("notion-not-found"), status: 404))
    }

    func testARefusedTokenThrows() {
        let data = Data(#"{"object":"error","status":401,"code":"unauthorized","message":"API token is invalid."}"#.utf8)
        XCTAssertThrowsError(try NotionPages.parseSearch(data, status: 401)) {
            XCTAssertEqual($0 as? LinkedServiceError, .unauthorized)
        }
        XCTAssertThrowsError(try NotionPages.parsePage(data)) {
            XCTAssertEqual($0 as? LinkedServiceError, .unauthorized)
        }
    }

    func testParentTitlesFromEitherKind() throws {
        XCTAssertEqual(try NotionPages.parseParentTitle(linkedFixture("notion-database")), "Eng tasks")
        XCTAssertEqual(try NotionPages.parseParentTitle(linkedFixture("notion-page")), "Q4 launch plan")
    }

    func testMeNamesTheIntegrationAndWorkspace() throws {
        let data = Data(#"{"object":"user","name":"Dex","type":"bot","bot":{"workspace_name":"Acme"}}"#.utf8)
        XCTAssertEqual(try NotionPages.parseMe(data), "Dex in Acme")
    }

    func testPageIDsFromURLs() {
        XCTAssertEqual(NotionPages.pageID(fromURL: "https://www.notion.so/Q4-launch-plan-598337872cf94fdf8782e53db20768a5"),
                       "598337872cf94fdf8782e53db20768a5")
        XCTAssertEqual(NotionPages.pageID(fromURL: "https://www.notion.so/acme/598337872CF94FDF8782E53DB20768A5?pvs=4"),
                       "598337872cf94fdf8782e53db20768a5")
        XCTAssertEqual(NotionPages.pageID(fromURL: "https://acme.notion.site/59833787-2cf9-4fdf-8782-e53db20768a5"),
                       "598337872cf94fdf8782e53db20768a5")
        XCTAssertEqual(NotionPages.pageID(fromURL: "https://www.notion.so/acme/d9824bdc84454327be8b5b47500af6ce?v=1111&p=be633bf1dfa0436db259571129a590e5"),
                       "be633bf1dfa0436db259571129a590e5")
        XCTAssertNil(NotionPages.pageID(fromURL: "https://example.com/598337872cf94fdf8782e53db20768a5"))
        XCTAssertNil(NotionPages.pageID(fromURL: "https://www.notion.so/settings"))
    }

    func testDashed() {
        XCTAssertEqual(NotionPages.dashed("598337872cf94fdf8782e53db20768a5"), "59833787-2cf9-4fdf-8782-e53db20768a5")
    }

    func testSearchRequestIsPagesOnlyWithABearerToken() throws {
        let request = NotionPages.searchRequest(for: "  launch ", token: "ntn_test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.notion.com/v1/search")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ntn_test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), NotionPages.version)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["query"] as? String, "launch")
        XCTAssertEqual((body["filter"] as? [String: String])?["value"], "page")
        XCTAssertNil(body["sort"])
    }

    func testAnEmptySearchIsTheMostRecentlyEdited() throws {
        let request = NotionPages.searchRequest(for: "", token: "ntn_test")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertNil(body["query"])
        XCTAssertEqual((body["sort"] as? [String: String])?["timestamp"], "last_edited_time")
    }

    func testPageRequestUsesTheDashedID() {
        let request = NotionPages.pageRequest(id: "598337872cf94fdf8782e53db20768a5", token: "t")
        XCTAssertEqual(request.url?.absoluteString, "https://api.notion.com/v1/pages/59833787-2cf9-4fdf-8782-e53db20768a5")
    }
}

final class LinkedCandidatesTests: XCTestCase {

    func testEachIsALaneOfItsOwnSource() {
        let issue = { (id: String) in LinearIssueMention(identifier: id, title: id, url: "", stateName: "", stateType: "") }
        let page = { (id: String) in NotionPageMention(pageID: id, title: id, url: "") }
        let found = LinkedCandidates(linear: [issue("A-1"), issue("A-2")], notion: [page("p")])
        XCTAssertEqual(found.lanes.map { $0.map(\.id) }, [["linearIssue:A-1", "linearIssue:A-2"], ["notionPage:p"]])
    }

    func testAChipOfEachSurvivesTheDraft() {
        let issue = Mention.linear(LinearIssueMention(identifier: "ENG-1", title: "Fix login", url: "u",
                                                      stateName: "Todo", stateType: "unstarted"))
        let page = Mention.notion(NotionPageMention(pageID: "p", title: "Plan", url: "https://notion.so/p",
                                                    parent: .page("q"), parentTitle: "Work"))
        let draft = ComposerChips.draft(from: [.chip(issue), .text(" "), .chip(page)])
        XCTAssertEqual(ComposerChips.chips(in: draft), [issue, page])
        XCTAssertEqual(ComposerAttachments.prompt(draft: draft, attachments: [],
                                                  mentions: ComposerChips.named(in: draft, known: [])),
                       "@Fix login @Plan\n\n@Fix login refers to Linear issue ENG-1 (u)\n@Plan refers to Notion page https://notion.so/p")
    }

    func testMentionsResolveInADraftLikeAnyOther() {
        let issue = Mention.linear(LinearIssueMention(
            identifier: "ENG-1", title: "Fix login", url: "u", stateName: "", stateType: ""))
        let resolved = SessionMentions.resolved(in: "see @Fix login please", picked: [issue], known: [])
        XCTAssertEqual(resolved, [issue])
    }
}
