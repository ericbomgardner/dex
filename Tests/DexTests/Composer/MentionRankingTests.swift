import XCTest
@testable import DexCore

final class MentionRankingTests: XCTestCase {


    // Ranking

    private struct Item: Mentionable {
        let title: String
        var id: String { title }
        var source: MentionSource { .dexSession }
        var detail: String { "" }
        var line: String? { nil }
    }

    private func items(_ titles: String...) -> [Item] { titles.map(Item.init) }

    func testABareAtTakesEachLaneInTurn() {
        let ranked = MentionRanking.ranked(
            query: "", lanes: [items("a1", "a2", "a3"), items("b1", "b2"), items("c1")], limit: 8)
        XCTAssertEqual(ranked.map(\.title), ["a1", "b1", "c1", "a2", "b2", "a3"])
    }

    func testATypedQueryRanksALeadingTitleFirstWhateverItsLane() {
        let ranked = MentionRanking.ranked(
            query: "dex", lanes: [items("fix the dex sidebar"), items("Dex taxes"), items("Dexterity")], limit: 8)
        XCTAssertEqual(Array(ranked.map(\.title).prefix(2)).sorted(), ["Dex taxes", "Dexterity"])
        XCTAssertEqual(ranked.last?.title, "fix the dex sidebar")
    }

    func testATieGoesToTheEarlierPlaceThenTheEarlierLane() {
        let ranked = MentionRanking.ranked(
            query: "plan", lanes: [items("other", "plan"), items("plan b")], limit: 8)
        XCTAssertEqual(ranked.map(\.title), ["plan b", "plan"])
    }

    func testNothingMatchingIsNoMenu() {
        XCTAssertEqual(MentionRanking.ranked(query: "zzz", lanes: [items("a")]), [])
    }

    func testASearchedLaneIsOfferedWhateverItsTitles() {
        let ranked = MentionRanking.ranked(
            query: "ENG-412", lanes: [items("Other")], searched: [items("Crash when the socket drops"), []])
        XCTAssertEqual(ranked.map(\.title), ["Crash when the socket drops"])
    }

    func testSearchedLanesKeepTheirOrderAndTakeTurnsWithTheRankedList() {
        let ranked = MentionRanking.ranked(
            query: "socket", lanes: [items("socket work")],
            searched: [items("Crash when the socket drops"), items("Q3 plan")])
        XCTAssertEqual(ranked.map(\.title), ["socket work", "Crash when the socket drops", "Q3 plan"])
    }


    // Resolved sessions

    private func session(_ title: String, resolved: Bool = false) -> Mention {
        .session(SessionMention(title: title, sessionID: title, rowID: title, folder: "d", isResolved: resolved))
    }

    func testAResolvedSessionGoesBelowALiveOneHoweverWellItMatches() {
        let found = MentionRanking.matches(
            for: "@probe",
            in: MentionCandidates(lanes: [[session("fix the probe rot")]],
                                  resolved: [session("probe", resolved: true), session("probe rot", resolved: true)]))
        XCTAssertEqual(found.map(\.title), ["fix the probe rot", "probe", "probe rot"])
    }


    func testABareAtLeavesResolvedSessionsOut() {
        let found = MentionRanking.matches(
            for: "@", in: MentionCandidates(lanes: [[session("live")]], resolved: [session("done", resolved: true)]))
        XCTAssertEqual(found.map(\.title), ["live"])
    }

    func testAResolvedSessionSaysSoBesideItsFolder() {
        XCTAssertEqual(session("done", resolved: true).detail, "d · resolved")
        XCTAssertEqual(session("live").detail, "d")
    }

    // What a service found by its own search

    private let socket = Mention.linear(LinearIssueMention(
        identifier: "ENG-412", title: "Crash when the socket drops", url: "u", stateName: "", stateType: "started"))
    private let described = Mention.notion(NotionPageMention(pageID: "p", title: "Q3 plan", url: "n"))

    func testAnIssueFoundByItsIdentifierIsOfferedWhateverItsTitle() {
        let found = MentionRanking.matches(
            for: "@ENG-412",
            in: MentionCandidates(lanes: [[.session(SessionMention(title: "Other", sessionID: "s", rowID: "s", folder: "d"))]],
                                  searched: [[socket], []], searchedFor: "ENG-412"))
        XCTAssertEqual(found, [socket])
    }

    func testAServicesMatchesKeepItsOrderAndTakeTurnsWithTheRankedList() {
        let session = Mention.session(SessionMention(title: "socket work", sessionID: "s", rowID: "s", folder: "d"))
        let found = MentionRanking.matches(
            for: "@socket",
            in: MentionCandidates(lanes: [[session]], searched: [[socket], [described]], searchedFor: "socket"))
        XCTAssertEqual(found, [session, socket, described])
    }


    /// What `@ENG` found is still showing while `@ENG-412` is asked, and a
    /// Return then would take an issue nobody named.
    func testAnswersToAnEarlierQueryMustMatchByTitle() {
        let other = Mention.linear(LinearIssueMention(
            identifier: "ENG-7", title: "Unrelated", url: "u7", stateName: "", stateType: "started"))
        let stale = MentionCandidates(searched: [[other, socket]], searchedFor: "ENG")
        XCTAssertEqual(MentionRanking.matches(for: "@ENG-412", in: stale), [])
        XCTAssertEqual(MentionRanking.matches(for: "@socket", in: stale), [socket])
    }

    func testABareAtShowsNothingFoundForAnEarlierQuery() {
        let session = Mention.session(SessionMention(title: "a", sessionID: "s", rowID: "s", folder: "d"))
        let stale = MentionCandidates(lanes: [[session]], searched: [[socket]], searchedFor: "crash")
        XCTAssertEqual(MentionRanking.matches(for: "@", in: stale), [session])
    }
}
