import XCTest
@testable import DexCore

final class SessionMentionsTests: XCTestCase {

    private let kestrel = SessionMention(title: "Kestrel MCP restart issue", sessionID: "uuid-kestrel",
                                       rowID: "kestrel", folder: "kestrel")
    private let sidebar = SessionMention(title: "Fix the sidebar", sessionID: "uuid-sidebar",
                                         rowID: "sidebar", folder: "dex")
    private let fixtures = SessionMention(title: "Fix the sidebar fixtures", sessionID: "uuid-fixtures",
                                          rowID: "fixtures", folder: "dex")
    private let probes = SessionMention(title: "Probe rot", sessionID: "uuid-probes",
                                        rowID: "probes", folder: "dex")

    private var candidates: [SessionMention] { [kestrel, sidebar, fixtures, probes] }

    private func titles(_ draft: String, limit: Int = 6) -> [String] {
        SessionMentions.matches(for: draft, in: candidates, limit: limit).map(\.title)
    }

    // When the menu is worth offering

    func testAnAtOnItsOwnAsksForEveryone() {
        XCTAssertEqual(SessionMentions.query(in: "@"), "")
        XCTAssertEqual(SessionMentions.query(in: "continue from @"), "")
    }

    func testTheQueryIsWhatFollowsTheAt() {
        XCTAssertEqual(SessionMentions.query(in: "pick up @Kestrel MCP"), "Kestrel MCP")
    }

    func testAnAtInsideAWordIsAnAddressNotAMention() {
        XCTAssertNil(SessionMentions.query(in: "mail me@example.com"))
        XCTAssertNil(SessionMentions.query(in: "the package is npm:@anthropic-ai/sdk"))
    }

    func testAnAtCanOpenAParenthesisOrQuote() {
        XCTAssertEqual(SessionMentions.query(in: "as before (@Kestrel"), "Kestrel")
        XCTAssertEqual(SessionMentions.query(in: "as \"@Kestrel"), "Kestrel")
    }

    func testProseWithNoAtOffersNothing() {
        XCTAssertNil(SessionMentions.query(in: "fix the sidebar"))
        XCTAssertEqual(titles("fix the sidebar"), [])
    }

    func testASpaceStraightAfterTheAtCloses() {
        XCTAssertNil(SessionMentions.query(in: "@ then some prose"))
    }

    func testTheMenuClosesOnceTheLineBreaks() {
        XCTAssertNil(SessionMentions.query(in: "@Kestrel\nand then"))
    }

    func testTextRunningOnPastAnyTitleCloses() {
        let long = "@" + String(repeating: "x", count: SessionMentions.longestQuery + 1)
        XCTAssertNil(SessionMentions.query(in: long))
    }

    func testTheLastAtIsTheOneBeingTyped() {
        XCTAssertEqual(SessionMentions.query(in: "@Kestrel MCP restart issue and @Fix"), "Fix")
    }

    // What it offers

    func testWithNothingTypedTheListIsOfferedInItsOwnOrder() {
        XCTAssertEqual(titles("@"), candidates.map(\.title))
        XCTAssertEqual(titles("@", limit: 2).count, 2)
    }

    func testATitleThatStartsWithTheQueryBeatsOneThatMerelyContainsIt() {
        XCTAssertEqual(titles("@prob").first, "Probe rot")
        XCTAssertEqual(titles("@fix").first, "Fix the sidebar")
    }

    func testSpacesInTheQueryAreTypedThroughTheTitle() {
        XCTAssertEqual(titles("@fix the side").first, "Fix the sidebar")
    }

    func testNothingMatchesNothing() {
        XCTAssertEqual(titles("@zzzz"), [])
    }

    // Which rows are offered

    func testOnlyTitledLocalRowsWithATranscriptAreOffered() {
        let untitled = SessionRowModel(session: AgentSession(
            cwd: "/tmp/new", startedAt: 1, hostKey: "new", state: .running, sessionId: "uuid-new"
        ))
        let unwritten = SessionRowModel(session: AgentSession(
            cwd: "/tmp/early", startedAt: 1, hostKey: "early", state: .starting, name: "Early"
        ))
        var rows = [makeRow("kestrel", state: .done), untitled, unwritten]

        XCTAssertEqual(SessionMentions.candidates(in: rows).map(\.rowID), ["kestrel"])
    }

    func testTheSessionBeingTypedAtIsNotOffered() {
        let rows = [makeRow("kestrel", state: .done), makeRow("probes", state: .done)]

        XCTAssertEqual(SessionMentions.candidates(in: rows, excluding: "kestrel").map(\.rowID),
                       ["probes"])
    }

    func testACandidateCarriesWhatTheMessageNeeds() {
        let row = makeRow("kestrel", state: .done, cwd: "/Users/me/Projects/kestrel")
        let found = SessionMentions.candidates(in: [row]).first

        XCTAssertEqual(found?.title, "kestrel")
        XCTAssertEqual(found?.sessionID, "uuid-kestrel")
        XCTAssertEqual(found?.folder, "kestrel")
    }

    // Taking one

    func testTakingASessionTypesItsTitleOutAndLeavesRoomToGoOn() {
        XCTAssertEqual(SessionMentions.accepting(kestrel, in: "pick up @kes"),
                       "pick up @Kestrel MCP restart issue ")
    }

    func testTakingASessionDoesNotDisturbProse() {
        XCTAssertEqual(SessionMentions.accepting(kestrel, in: "look at this"), "look at this")
    }

    // What the message names

    func testAPickStillInTheTextIsNamed() {
        let named = SessionMentions.resolved(in: "continue @Kestrel MCP restart issue please",
                                             picked: [kestrel], known: [])

        XCTAssertEqual(named, [kestrel])
    }

    func testAPickDeletedFromTheTextIsDropped() {
        XCTAssertEqual(SessionMentions.resolved(in: "continue please", picked: [kestrel], known: []), [])
    }

    func testATitleTypedOutByHandResolvesAgainstTheList() {
        let named = SessionMentions.resolved(in: "see @Probe rot", picked: [], known: candidates)

        XCTAssertEqual(named, [probes])
    }

    func testSessionsAreNamedInTheOrderTheTextNamesThem() {
        let named = SessionMentions.resolved(in: "@Probe rot then @Kestrel MCP restart issue",
                                             picked: [kestrel], known: candidates)

        XCTAssertEqual(named.map(\.rowID), ["probes", "kestrel"])
    }

    func testAPickIsNamedOnceHoweverManyListsHoldIt() {
        let named = SessionMentions.resolved(in: "@Probe rot", picked: [probes], known: candidates)

        XCTAssertEqual(named.count, 1)
    }

    /// `@Fix the sidebar` is the start of `@Fix the sidebar fixtures`, and the
    /// longer name is the one the text says.
    func testATitleThatStartsALongerOneIsNotNamedByIt() {
        let named = SessionMentions.resolved(in: "@Fix the sidebar fixtures", picked: [],
                                             known: candidates)

        XCTAssertEqual(named, [fixtures])
    }

    func testATitleFollowedByPunctuationIsStillNamed() {
        let named = SessionMentions.resolved(in: "@Probe rot's findings", picked: [], known: candidates)

        XCTAssertEqual(named, [probes])
    }

    // What the session reads

    func testEachNamedSessionGetsALineUnderTheMessage() {
        let prompt = ComposerAttachments.prompt(draft: "continue @Probe rot", attachments: [],
                                                mentions: [.session(probes)])

        XCTAssertEqual(prompt, """
        continue @Probe rot

        @Probe rot refers to session `uuid-probes`
        """)
    }

    func testTheTranscriptIsLookedUpAtSendAndNamedBesideTheId() {
        let prompt = ComposerAttachments.outgoing(
            draft: "continue @Probe rot",
            attachments: [],
            mentions: [.session(probes)],
            locating: { "/Users/me/.claude/projects/-p/\($0).jsonl" }
        )

        XCTAssertEqual(prompt, """
        continue @Probe rot

        @Probe rot refers to session `uuid-probes` (transcript: `/Users/me/.claude/projects/-p/uuid-probes.jsonl`)
        """)
    }

    func testATranscriptThatCannotBeFoundLeavesTheIdOnItsOwn() {
        let prompt = ComposerAttachments.outgoing(draft: "continue @Probe rot", attachments: [],
                                                  mentions: [.session(probes)], locating: { _ in nil })

        XCTAssertEqual(prompt, "continue @Probe rot\n\n@Probe rot refers to session `uuid-probes`")
    }

    func testAttachedFilesComeBeforeNamedSessions() {
        let shot = ComposerAttachment(path: "/tmp/shot.png")
        let prompt = ComposerAttachments.prompt(draft: "look", attachments: [shot], mentions: [.session(probes)])

        XCTAssertEqual(prompt, "look\n\nAttached: `/tmp/shot.png`\n@Probe rot refers to session `uuid-probes`")
    }

    // A pasted link


    func testAPastedLinkWithNoNameStillNamesTheSession() {
        XCTAssertEqual(SessionMention(SessionLink(sessionID: "0123456789abcdef"))?.title, "Session 01234567")
    }

}
