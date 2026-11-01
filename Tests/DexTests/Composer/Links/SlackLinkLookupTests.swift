import XCTest
@testable import DexCore

final class SlackLinkLookupTests: XCTestCase {

    private func json(_ object: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: object)
    }

    /// Answers each Web API method from the table, and remembers what was asked.
    private func slack(
        token: String? = "xoxp-1",
        _ answers: [String: [String: Any]]
    ) -> (SlackLinkLookup, Lock<[URLRequest]>) {
        let asked = Lock<[URLRequest]>([])
        let data = answers.mapValues { try! JSONSerialization.data(withJSONObject: $0) }
        let lookup = SlackLinkLookup(token: { token }) { request in
            asked.withLock { $0.append(request) }
            let method = request.url!.lastPathComponent
            return data[method] ?? Data(#"{"ok":false,"error":"unknown_method"}"#.utf8)
        }
        return (lookup, asked)
    }

    private func query(_ request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    private let channelInfo: [String: Any] = ["ok": true, "channel": ["name": "eng"]]
    private let user: [String: Any] = ["ok": true, "user": ["profile": ["display_name": "Ana", "real_name": "Ana B"]]]

    func testAMessageBecomesItsTextByItsAuthorInItsChannel() async throws {
        let (lookup, asked) = slack([
            "conversations.info": channelInfo,
            "conversations.history": ["ok": true, "messages": [["ts": "1700000000.123456", "user": "U1", "text": "Ship it <@U1>?"]]],
            "users.info": user,
        ])
        let found = try await lookup.resolve(PastedLink(url: "https://acme.slack.com/archives/C0123ABC/p1700000000123456")!)
        XCTAssertEqual(found, LinkResolution(title: "Ship it @Ana?", detail: "Ana in #eng"))

        let history = asked.value.first { $0.url!.lastPathComponent == "conversations.history" }!
        XCTAssertEqual(query(history)["latest"], "1700000000.123456")
        XCTAssertEqual(query(history)["inclusive"], "true")
        XCTAssertEqual(history.value(forHTTPHeaderField: "Authorization"), "Bearer xoxp-1")
    }

    func testAReplyIsReadFromItsThread() async throws {
        let (lookup, asked) = slack([
            "conversations.info": channelInfo,
            "conversations.replies": ["ok": true, "messages": [
                ["ts": "1700000000.123456", "user": "U1", "text": "parent"],
                ["ts": "1700000500.000200", "user": "U1", "text": "the reply"],
            ]],
            "users.info": user,
        ])
        let found = try await lookup.resolve(PastedLink(url: "https://acme.slack.com/archives/C0123ABC/p1700000500000200?thread_ts=1700000000.123456&cid=C0123ABC")!)
        XCTAssertEqual(found?.title, "the reply")
        let replies = asked.value.first { $0.url!.lastPathComponent == "conversations.replies" }!
        XCTAssertEqual(query(replies)["ts"], "1700000000.123456")
        XCTAssertEqual(query(replies)["oldest"], "1700000500.000200")
    }

    func testAThreadViewIsItsParent() async throws {
        let (lookup, _) = slack([
            "conversations.info": channelInfo,
            "conversations.replies": ["ok": true, "messages": [["ts": "1700000000.123456", "text": "kickoff"]]],
        ])
        let found = try await lookup.resolve(PastedLink(url: "https://app.slack.com/client/T1/C0123ABC/thread/C0123ABC-1700000000.123456")!)
        XCTAssertEqual(found, LinkResolution(title: "kickoff", detail: "#eng"))
    }

    func testAChannelIsItsName() async throws {
        let (lookup, asked) = slack(["conversations.info": channelInfo])
        let found = try await lookup.resolve(PastedLink(url: "https://app.slack.com/client/T1/C0123ABC")!)
        XCTAssertEqual(found?.title, "#eng")
        XCTAssertEqual(asked.value.count, 1)
    }

    func testAMessageThatIsGoneSaysWhereItWas() async throws {
        let (lookup, _) = slack([
            "conversations.info": channelInfo,
            "conversations.history": ["ok": true, "messages": [["ts": "1699999999.000001", "text": "a neighbour"]]],
        ])
        let found = try await lookup.resolve(PastedLink(url: "https://acme.slack.com/archives/C0123ABC/p1700000000123456")!)
        XCTAssertEqual(found?.title, "Message in #eng")
    }

    func testNoTokenIsNothingToAskWith() async throws {
        let (lookup, asked) = slack(token: nil, [:])
        let found = try await lookup.resolve(PastedLink(url: "https://acme.slack.com/archives/C0123ABC")!)
        XCTAssertNil(found)
        XCTAssertTrue(asked.value.isEmpty)
    }

    func testSlacksOwnErrorIsThrown() async {
        let (lookup, _) = slack(["conversations.info": ["ok": false, "error": "channel_not_found"]])
        do {
            _ = try await lookup.resolve(PastedLink(url: "https://acme.slack.com/archives/C0123ABC")!)
            XCTFail("should throw")
        } catch {
            XCTAssertEqual(error as? PastedLinkError, .service("channel_not_found"))
        }
    }

    func testMrkdwnReadsAsPlainText() {
        XCTAssertEqual(SlackAPI.plainText("see <https://x.test|the doc> in <#C1|eng> &amp; <!here>\nok"),
                       "see the doc in #eng & @here ok")
        XCTAssertEqual(SlackAPI.mentionedUsers("<@U1> and <@W2|bo>"), ["U1", "W2"])
    }

    func testAuthTestNamesTheWorkspaceAndUser() throws {
        let who = try SlackAPI.identity(in: json(["ok": true, "team": "Acme", "user": "ada"]))
        XCTAssertEqual(who.team, "Acme")
        XCTAssertEqual(who.user, "ada")
    }
}
