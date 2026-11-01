import Security
import XCTest
@testable import DexCore

final class APIKeyCheckTests: XCTestCase {
    private let key = "sk-ant-test-0123456789"

    func testAKeyTheModelsListAnswersIsValid() async {
        let (transport, sent) = answering(status: 200)
        let result = await APIKeyCheck.check(key, transport: transport)
        XCTAssertEqual(result, .valid)
        XCTAssertEqual(sent.value.count, 1)
    }

    func testA401IsAnInvalidKey() async {
        let (transport, _) = answering(status: 401)
        let result = await APIKeyCheck.check(key, transport: transport)
        XCTAssertEqual(result, .invalid)
    }

    func testANetworkFailureSaysItCouldNotCheck() async {
        let transport: APIKeyCheck.Transport = { _ in throw URLError(.notConnectedToInternet) }
        let result = await APIKeyCheck.check(key, transport: transport)
        guard case .unchecked = result else { return XCTFail("\(result)") }
    }

    func testAnotherStatusSaysItCouldNotCheck() async {
        let (transport, _) = answering(status: 529)
        let result = await APIKeyCheck.check(key, transport: transport)
        XCTAssertEqual(result, .unchecked("Anthropic answered HTTP 529"))
    }

    func testTheKeyGoesInTheHeaderAndNeverTheURL() async throws {
        let (transport, sent) = answering(status: 200)
        _ = await APIKeyCheck.check("  \(key)\n", transport: transport)
        let request = try XCTUnwrap(sent.value.first)
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertFalse(url.contains(key), url)
        XCTAssertFalse(url.contains("sk-ant"), url)
        XCTAssertEqual(request.url?.host, "api.anthropic.com")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertNil(request.httpBody)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertNotNil(request.value(forHTTPHeaderField: "anthropic-version"))
        let others = (request.allHTTPHeaderFields ?? [:]).filter { $0.key.lowercased() != "x-api-key" }
        XCTAssertFalse(others.values.contains { $0.contains(key) })
    }

    func testTheShellKeyIsCheckedOnceButAFailedCheckIsTriedAgain() async {
        let shellKey = "sk-ant-shell-\(UUID().uuidString)"
        let failures = Lock(0)
        let flaky: APIKeyCheck.Transport = { _ in
            failures.withLock { $0 += 1 }
            throw URLError(.timedOut)
        }
        guard case .unchecked = await APIKeyCheck.shellKey(shellKey, transport: flaky) else { return XCTFail() }
        guard case .unchecked = await APIKeyCheck.shellKey(shellKey, transport: flaky) else { return XCTFail() }
        XCTAssertEqual(failures.value, 2)

        let (transport, sent) = answering(status: 200)
        let first = await APIKeyCheck.shellKey(shellKey, transport: transport)
        let second = await APIKeyCheck.shellKey(shellKey, transport: transport)
        XCTAssertEqual(first, .valid)
        XCTAssertEqual(second, .valid)
        XCTAssertEqual(sent.value.count, 1)
    }

    func testARefusedKeyIsNotSavedAndTheOldOneStays() async throws {
        let keychain = FakeKeychain()
        keychain.put("sk-ant-old")

        let (transport, _) = answering(status: 401)
        let result = try await save("sk-ant-wrong", to: keychain, transport: transport)
        XCTAssertEqual(result, .invalid)
        XCTAssertEqual(keychain.apiKey, "sk-ant-old")
    }

    func testARefusedKeyWithNothingSavedLeavesNothingSaved() async throws {
        let keychain = FakeKeychain()
        let (transport, _) = answering(status: 401)
        _ = try await save("sk-ant-wrong", to: keychain, transport: transport)
        XCTAssertNil(keychain.apiKey)
    }

    func testAKeyThatCouldNotBeCheckedIsSavedAnyway() async throws {
        let keychain = FakeKeychain()
        keychain.put("sk-ant-old")

        let offline: APIKeyCheck.Transport = { _ in throw URLError(.notConnectedToInternet) }
        let result = try await save("sk-ant-new", to: keychain, transport: offline)
        guard case .unchecked = result else { return XCTFail("\(result)") }
        XCTAssertEqual(keychain.apiKey, "sk-ant-new")

        for status in [403, 500] {
            let (transport, _) = answering(status: status)
            let result = try await save("sk-ant-\(status)", to: keychain, transport: transport)
            XCTAssertEqual(result, .unchecked("Anthropic answered HTTP \(status)"))
            XCTAssertEqual(keychain.apiKey, "sk-ant-\(status)")
        }
    }

    func testAValidKeyIsSaved() async throws {
        let keychain = FakeKeychain()
        let (transport, _) = answering(status: 200)
        let result = try await save(" sk-ant-good\n", to: keychain, transport: transport)
        XCTAssertEqual(result, .valid)
        XCTAssertEqual(keychain.apiKey, "sk-ant-good")
    }

    func testClearingRemovesTheKey() throws {
        let keychain = FakeKeychain()
        keychain.put("sk-ant-old")
        try keychain.saved.save("")
        XCTAssertNil(keychain.apiKey)
        XCTAssertEqual(keychain.saved.reading(), .missing)
    }

    /// A key a differently signed build saved can't be deleted by this one, and
    /// says so rather than leaving the old key unreadable.
    func testAKeyTheKeychainWontReplaceSaysWhatToDo() async {
        let keychain = FakeKeychain()
        keychain.put("sk-ant-old")
        keychain.refuse(errSecAuthFailed)
        let (transport, _) = answering(status: 200)
        do {
            _ = try await save("sk-ant-new", to: keychain, transport: transport)
            XCTFail("saved over an item it can't delete")
        } catch {
            XCTAssertEqual(error as? TokenNotReplaced, TokenNotReplaced(label: SavedAPIKey.label, status: errSecAuthFailed))
        }
    }

    private func save(_ key: String, to keychain: FakeKeychain, transport: @escaping APIKeyCheck.Transport) async throws -> APIKeyCheck {
        let saved = keychain.saved
        return try await APIKeyCheck.save(key, transport: transport) { try saved.save($0) }
    }

    private func answering(status: Int) -> (APIKeyCheck.Transport, Lock<[URLRequest]>) {
        let sent = Lock<[URLRequest]>([])
        let transport: APIKeyCheck.Transport = { request in
            sent.withLock { $0.append(request) }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
            return (Data(), response)
        }
        return (transport, sent)
    }
}
