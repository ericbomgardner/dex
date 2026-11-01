import XCTest
@testable import DexCore

/// A stand-in for the network: answers by route, and remembers what was asked.
final class FakeLinkedServer: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [(matches: @Sendable (URLRequest) -> Bool, status: Int, body: Data)] = []
    private var asked: [URLRequest] = []

    func answer(status: Int = 200, _ body: Data, when matches: @escaping @Sendable (URLRequest) -> Bool) {
        lock.withLock { routes.append((matches, status, body)) }
    }

    var requests: [URLRequest] { lock.withLock { asked } }

    var transport: HTTPTransport {
        { [self] request in
            let route = lock.withLock {
                asked.append(request)
                return routes.first { $0.matches(request) }
            }
            let status = route?.status ?? 500
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (route?.body ?? Data(), response)
        }
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: @Sendable () -> Date { { [self] in lock.withLock { current } } }

    func advance(_ seconds: TimeInterval) {
        lock.withLock { current += seconds }
    }
}

private func body(_ request: URLRequest) -> String {
    request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
}

final class LinearClientTests: XCTestCase {

    func testNoTokenAsksNothing() async throws {
        let server = FakeLinkedServer()
        let client = LinearClient(secrets: MemorySecrets(), transport: server.transport)
        do {
            _ = try await client.search("")
            XCTFail("expected no token")
        } catch {
            XCTAssertEqual(error as? LinkedServiceError, .noToken)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testAnswersAreKeptForAWhile() async throws {
        let server = FakeLinkedServer()
        let clock = Clock()
        server.answer(try linkedFixture("linear-recent")) { body($0).contains("assignedIssues") }
        let client = LinearClient(secrets: MemorySecrets([.linear: "lin_api_test"]), transport: server.transport,
                                  lifetime: 60, now: clock.now)

        let first = try await client.search("")
        let again = try await client.search("  ")
        XCTAssertEqual(first, again)
        XCTAssertEqual(server.requests.count, 1)
        let cached = await client.cached("")
        XCTAssertEqual(cached, first)

        clock.advance(61)
        let noLongerCached = await client.cached("")
        XCTAssertNil(noLongerCached)
        _ = try await client.search("")
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAnIdentifierIsLookedUpAndPutFirst() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("linear-issue")) { body($0).contains("query Issue") }
        server.answer(try linkedFixture("linear-search")) { body($0).contains("query Search") }
        let client = LinearClient(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)

        let found = try await client.search("eng-123")
        XCTAssertEqual(found.map(\.identifier), ["ENG-123", "ENG-412", "OPS-9"])
        XCTAssertEqual(server.requests.count, 2)
        XCTAssertTrue(server.requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "k" })
    }

    func testAnIdentifierThatDoesntExistStillSearchesTitles() async throws {
        let server = FakeLinkedServer()
        server.answer(status: 400, try linkedFixture("linear-not-found")) { body($0).contains("query Issue") }
        server.answer(try linkedFixture("linear-search")) { body($0).contains("query Search") }
        let client = LinearClient(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)

        let found = try await client.search("ENG-999")
        XCTAssertEqual(found.map(\.identifier), ["ENG-412", "OPS-9"])
    }

    func testARefusedKeyThrowsUnauthorized() async throws {
        let server = FakeLinkedServer()
        server.answer(status: 401, try linkedFixture("linear-unauthenticated")) { _ in true }
        let client = LinearClient(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)
        do {
            _ = try await client.search("webhook")
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? LinkedServiceError, .unauthorized)
        }
    }

    func testLookUpByURL() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("linear-issue")) { body($0).contains(#""id":"ENG-123""#) }
        let client = LinearClient(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)

        let issue = try await client.issue(at: "https://linear.app/acme/issue/ENG-123/crash")
        XCTAssertEqual(issue?.title, "Crash when the socket drops mid-turn")
        XCTAssertEqual(issue?.stateName, "Canceled")
        let notLinear = try await client.issue(at: "https://example.com/issue/ENG-123")
        XCTAssertNil(notLinear)
        XCTAssertEqual(server.requests.count, 1)
    }
}

final class NotionClientTests: XCTestCase {

    func testParentsAreNamedAfterTheSearch() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("notion-search")) { $0.url?.path == "/v1/search" }
        server.answer(try linkedFixture("notion-database")) { $0.url?.path.hasPrefix("/v1/databases/") == true }
        let client = NotionClient(secrets: MemorySecrets([.notion: "ntn_test"]), transport: server.transport)

        let found = try await client.search("")
        XCTAssertEqual(found[0].parentTitle, "Roadmap")
        XCTAssertNil(found[1].parentTitle)

        let learned = await client.resolveParents(of: found)
        XCTAssertTrue(learned)
        XCTAssertEqual(server.requests.map { $0.url?.path },
                       ["/v1/search", "/v1/databases/d9824bdc-8445-4327-be8b-5b47500af6ce"])

        let again = await client.cached("")
        XCTAssertEqual(again?[1].detail, "Eng tasks")
        let nothingNew = await client.resolveParents(of: found)
        XCTAssertFalse(nothingNew)
        XCTAssertEqual(server.requests.count, 2)
    }

    func testAParentItCantSeeIsNotAskedAgain() async throws {
        let server = FakeLinkedServer()
        server.answer(status: 404, try linkedFixture("notion-not-found")) { _ in true }
        let client = NotionClient(secrets: MemorySecrets([.notion: "t"]), transport: server.transport)
        let orphan = NotionPageMention(pageID: "p", title: "x", url: "", parent: .page("q"))

        let first = await client.resolveParents(of: [orphan])
        let second = await client.resolveParents(of: [orphan])
        XCTAssertFalse(first)
        XCTAssertFalse(second)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testLookUpByURL() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("notion-page")) {
            $0.url?.path == "/v1/pages/59833787-2cf9-4fdf-8782-e53db20768a5"
        }
        let client = NotionClient(secrets: MemorySecrets([.notion: "t"]), transport: server.transport)

        let page = try await client.page(at: "https://www.notion.so/Q4-launch-plan-598337872cf94fdf8782e53db20768a5")
        XCTAssertEqual(page?.title, "Q4 launch plan")
        XCTAssertEqual(page?.emoji, "🚀")
        XCTAssertEqual(server.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer t")
    }

    func testAPageItCantSeeIsNil() async throws {
        let server = FakeLinkedServer()
        server.answer(status: 404, try linkedFixture("notion-not-found")) { _ in true }
        let client = NotionClient(secrets: MemorySecrets([.notion: "t"]), transport: server.transport)
        let page = try await client.page(id: "598337872cf94fdf8782e53db20768a5")
        XCTAssertNil(page)
    }
}
