import Security
import XCTest
@testable import DexCore
@testable import DexUI

@MainActor
final class LinkedWorkTests: XCTestCase {

    func testNoTokensIsNoCandidatesAndNoRequests() async {
        let server = FakeLinkedServer()
        let work = LinkedWork(secrets: MemorySecrets(), transport: server.transport)
        await work.load()
        XCTAssertEqual(work.linearStatus, .noToken)
        XCTAssertEqual(work.notionStatus, .noToken)
        let found = await work.candidates(for: "")
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(server.requests.isEmpty)
    }

    func testOneFailingServiceLeavesTheOtherAndSaysWhy() async throws {
        let server = FakeLinkedServer()
        server.answer(status: 401, try linkedFixture("linear-unauthenticated")) { $0.url?.host == "api.linear.app" }
        server.answer(try linkedFixture("notion-search")) { $0.url?.path == "/v1/search" }
        let work = LinkedWork(secrets: MemorySecrets([.linear: "bad", .notion: "good"]), transport: server.transport)

        let found = await work.candidates(for: "")
        XCTAssertTrue(found.linear.isEmpty)
        XCTAssertEqual(found.notion.count, 4)
        guard case .failed(let message, _) = work.linearStatus else {
            return XCTFail("expected Linear to have failed, got \(work.linearStatus)")
        }
        XCTAssertEqual(message, "Linear refused the token.")
        guard case .connected = work.notionStatus else {
            return XCTFail("expected Notion to be connected, got \(work.notionStatus)")
        }
    }

    func testAKeystrokeThatIsOvertakenAsksNothing() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("linear-search")) { _ in true }
        let work = LinkedWork(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)

        let typing = Task { await work.candidates(for: "web") }
        typing.cancel()
        let found = await typing.value
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(work.linearStatus, .unchecked)
    }

    func testACachedQueryAnswersWithoutWaiting() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("linear-search")) { _ in true }
        let work = LinkedWork(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)

        _ = await work.candidates(for: "web")
        let cached = Task { await work.candidates(for: "web") }
        cached.cancel()
        let found = await cached.value
        XCTAssertEqual(found.linear.map(\.identifier), ["ENG-412", "OPS-9"])
        XCTAssertEqual(server.requests.count, 1)
    }

    func testAPastedLinkBecomesAMention() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("linear-issue")) { _ in true }
        let work = LinkedWork(secrets: MemorySecrets([.linear: "k"]), transport: server.transport)

        let mention = await work.lookUp(url: "https://linear.app/acme/issue/ENG-123/crash")
        XCTAssertEqual(mention?.id, "linearIssue:ENG-123")
        let notion = await work.lookUp(url: "https://www.notion.so/Q4-598337872cf94fdf8782e53db20768a5")
        XCTAssertNil(notion)
        XCTAssertEqual(server.requests.count, 1)
    }

    func testRemovingATokenSaysSo() async {
        let secrets = MemorySecrets([.notion: "t"])
        let work = LinkedWork(secrets: secrets, transport: FakeLinkedServer().transport)
        await work.load()
        XCTAssertEqual(work.notionStatus, .unchecked)
        await work.saveToken("  ", for: .notion)
        XCTAssertEqual(work.notionStatus, .noToken)
        XCTAssertNil(secrets.secret(for: .notion))
    }

    // Reading the tokens

    func testNothingIsReadUntilSomethingNeedsATokenAndThenOffTheMainThread() async {
        let secrets = CountingSecrets(MemorySecrets([.linear: "k"]))
        let work = LinkedWork(secrets: secrets, transport: FakeLinkedServer().transport)
        XCTAssertEqual(work.linearStatus, .reading)
        XCTAssertEqual(work.notionStatus, .reading)
        XCTAssertEqual(secrets.reads, [])
        await work.load()
        await work.load()
        XCTAssertEqual(work.linearStatus, .unchecked)
        XCTAssertEqual(work.notionStatus, .noToken)
        XCTAssertEqual(secrets.reads, [false, false])
    }

    func testATokenTheKeychainRefusesIsUnreadableNotMissing() async {
        let server = FakeLinkedServer()
        let secrets = MemorySecrets([.linear: "k"], refused: [.linear: errSecInteractionNotAllowed])
        let work = LinkedWork(secrets: secrets, transport: server.transport)
        let found = await work.candidates(for: "")
        XCTAssertTrue(found.isEmpty)
        XCTAssertTrue(server.requests.isEmpty)
        XCTAssertEqual(work.linearStatus, .unreadable(errSecInteractionNotAllowed))
        XCTAssertFalse(work.hasToken(.linear))
    }

    func testRetryingReadsAgainAndChecks() async throws {
        let server = FakeLinkedServer()
        server.answer(Data(#"{"data":{"viewer":{"name":"Ada"}}}"#.utf8)) { _ in true }
        let secrets = MemorySecrets([.linear: "k"], refused: [.linear: errSecAuthFailed])
        let work = LinkedWork(secrets: secrets, transport: server.transport)
        await work.load()
        XCTAssertEqual(work.linearStatus, .unreadable(errSecAuthFailed))
        secrets.refuse(.linear, nil)
        await work.retry(.linear)
        guard case .connected(let who, _) = work.linearStatus else {
            return XCTFail("expected Linear to be connected, got \(work.linearStatus)")
        }
        XCTAssertEqual(who, "Ada")
    }

    func testAKeychainThatStartsRefusingMidSessionSaysSo() async throws {
        let server = FakeLinkedServer()
        server.answer(try linkedFixture("linear-search")) { _ in true }
        let secrets = MemorySecrets([.linear: "k"])
        let work = LinkedWork(secrets: secrets, transport: server.transport)
        await work.load()
        secrets.refuse(.linear, errSecInteractionNotAllowed)
        let found = await work.candidates(for: "web")
        XCTAssertTrue(found.isEmpty)
        XCTAssertEqual(work.linearStatus, .unreadable(errSecInteractionNotAllowed))
    }

    func testReplacingAnUnreadableToken() async {
        let secrets = MemorySecrets([.notion: "old"], refused: [.notion: errSecAuthFailed])
        let work = LinkedWork(secrets: secrets, transport: FakeLinkedServer().transport)
        await work.load()
        XCTAssertEqual(work.notionStatus, .unreadable(errSecAuthFailed))
        await work.saveToken("new", for: .notion)
        XCTAssertEqual(secrets.secret(for: .notion), "new")
        XCTAssertFalse(work.notionStatus.isUnreadable)
    }

    // Saves one at a time

    func testRemovingRightAfterSavingLeavesNoToken() async {
        let secrets = RacySecrets()
        let work = LinkedWork(secrets: secrets, transport: FakeLinkedServer().transport)
        await work.load()
        let saving = Task { await work.saveToken("b", for: .notion) }
        let removing = Task { await work.saveToken("", for: .notion) }
        await saving.value
        await removing.value
        XCTAssertNil(secrets.secret(for: .notion))
        XCTAssertEqual(work.notionStatus, .noToken)
    }

    func testACheckThatAnswersAfterARemoveLeavesNoToken() async throws {
        let viewer = Data(#"{"data":{"viewer":{"name":"Ada"}}}"#.utf8)
        let slow: HTTPTransport = { request in
            try await Task.sleep(for: .milliseconds(300))
            return (viewer, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let work = LinkedWork(secrets: MemorySecrets(), transport: slow)
        await work.load()
        let saving = Task { await work.saveToken("k", for: .linear) }
        while work.linearStatus != .unchecked { try await Task.sleep(for: .milliseconds(5)) }
        await work.saveToken("", for: .linear)
        await saving.value
        XCTAssertEqual(work.linearStatus, .noToken)
    }

    func testTwoQuickSavesKeepTheSecond() async {
        let secrets = RacySecrets()
        let work = LinkedWork(secrets: secrets, transport: FakeLinkedServer().transport)
        await work.load()
        let first = Task { await work.saveToken("a", for: .notion) }
        let second = Task { await work.saveToken("b", for: .notion) }
        await first.value
        await second.value
        XCTAssertEqual(secrets.secret(for: .notion), "b")
        if case .failed(let message, _) = work.notionStatus {
            XCTAssertFalse(message.hasPrefix("Couldn't save"), message)
        }
    }
}

/// Saves as the keychain does, a delete then an add with a gap between, so two
/// at once interleave.
private final class RacySecrets: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [LinkedService: String] = [:]

    func reading(for service: LinkedService) -> TokenReading {
        lock.withLock { values[service].map(TokenReading.found) ?? .missing }
    }

    func setSecret(_ value: String?, for service: LinkedService) throws {
        lock.withLock { values[service] = nil }
        Thread.sleep(forTimeInterval: 0.05)
        guard let value else { return }
        try lock.withLock {
            guard values[service] == nil else { throw KeychainError(status: errSecDuplicateItem) }
            values[service] = value
        }
    }
}

/// Records whether each read ran on the main thread.
private final class CountingSecrets: SecretStore, @unchecked Sendable {
    let inner: MemorySecrets
    private let lock = NSLock()
    private var onMain: [Bool] = []

    init(_ inner: MemorySecrets) {
        self.inner = inner
    }

    var reads: [Bool] { lock.withLock { onMain } }

    func reading(for service: LinkedService) -> TokenReading {
        lock.withLock { onMain.append(Thread.isMainThread) }
        return inner.reading(for: service)
    }

    func setSecret(_ value: String?, for service: LinkedService) throws {
        try inner.setSecret(value, for: service)
    }
}
