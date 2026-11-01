import Security
import XCTest
@testable import DexCore

final class SessionCredentialTests: XCTestCase {

    private func apiKey(shell: String?, saved: TokenReading, hostTakesKey: Bool = true) throws -> String {
        try SessionCredential.apiKey(shell: shell, saved: { saved }, hostTakesKey: hostTakesKey)
    }

    func testTheLoginShellsKeyComesBeforeTheSavedOne() throws {
        let found = SessionCredential.resolve(shell: "sk-shell", saved: "sk-saved")
        XCTAssertEqual(found?.key, "sk-shell")
        XCTAssertEqual(found?.source, .shell)
        XCTAssertEqual(try apiKey(shell: "sk-shell", saved: .found("sk-saved")), "sk-shell")
    }

    func testAShellKeyNeverAsksTheKeychain() throws {
        let key = try SessionCredential.apiKey(shell: "sk-shell", saved: {
            XCTFail("the keychain was asked")
            return .unreadable(errSecInteractionNotAllowed)
        }, hostTakesKey: true)
        XCTAssertEqual(key, "sk-shell")
    }

    func testTheSavedKeyIsUsedWhenTheShellHasNone() throws {
        for shell in [nil, "", "  \n"] {
            let found = SessionCredential.resolve(shell: shell, saved: " sk-saved\n")
            XCTAssertEqual(found?.key, "sk-saved")
            XCTAssertEqual(found?.source, .saved)
            XCTAssertEqual(try apiKey(shell: shell, saved: .found("sk-saved")), "sk-saved")
        }
    }

    func testNoKeyRefusesTheSessionAndSaysWhereToAddOne() {
        XCTAssertNil(SessionCredential.resolve(shell: nil, saved: " "))
        for saved in [TokenReading.missing, .found("  ")] {
            XCTAssertThrowsError(try apiKey(shell: nil, saved: saved)) { error in
                XCTAssertEqual(error as? SessionCredential.Refusal, .noKey)
                let said = error.localizedDescription
                XCTAssertTrue(said.contains("API key"), said)
                XCTAssertTrue(said.contains("Settings"), said)
            }
        }
    }

    func testAKeychainThatWontAnswerIsItsOwnRefusal() {
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled] {
            XCTAssertThrowsError(try apiKey(shell: nil, saved: .unreadable(status))) { error in
                XCTAssertEqual(error as? SessionCredential.Refusal, .keychainUnreadable)
                XCTAssertEqual(error.localizedDescription, "Dex couldn't read the API key from the keychain.")
            }
        }
    }

    func testAHostThatWouldDropTheKeyIsRefusedRatherThanRunOnTheLogin() {
        XCTAssertThrowsError(try apiKey(shell: "sk-shell", saved: .missing, hostTakesKey: false)) { error in
            XCTAssertEqual(error as? SessionCredential.Refusal, .hostDropsKey)
        }
    }

    func testTheSavedKeyRoundTripsThroughTheKeychain() throws {
        let keychain = FakeKeychain()
        XCTAssertEqual(keychain.saved.reading(), .missing)
        try keychain.saved.save("  sk-one \n")
        XCTAssertEqual(keychain.saved.reading(), .found("sk-one"))
        try keychain.saved.save("sk-two")
        XCTAssertEqual(keychain.apiKey, "sk-two")
        try keychain.saved.save(" ")
        XCTAssertEqual(keychain.saved.reading(), .missing)
        XCTAssertNil(keychain.apiKey)
    }

    func testAKeyTheKeychainWontHandOverIsUnreadable() {
        let keychain = FakeKeychain()
        keychain.put("sk-saved")
        keychain.refuse(errSecInteractionNotAllowed)
        XCTAssertEqual(keychain.saved.reading(), .unreadable(errSecInteractionNotAllowed))
    }

    @MainActor
    func testAStartFindsTheSavedKeyOrSaysWhy() async {
        let keychain = FakeKeychain()
        let lookup = KeyLookup(readShell: { nil }, readSaved: { keychain.saved.reading() })

        func start() async -> Result<String?, any Error> {
            await withCheckedContinuation { continuation in
                lookup.withKey(hostTakesKey: true) { continuation.resume(returning: $0) }
            }
        }

        guard case .failure(let missing) = await start() else { return XCTFail("started with no key") }
        XCTAssertEqual(missing as? SessionCredential.Refusal, .noKey)

        keychain.put("sk-saved")
        let found = await start()
        XCTAssertEqual(try? found.get(), "sk-saved")

        keychain.refuse(errSecInteractionNotAllowed)
        guard case .failure(let unreadable) = await start() else { return XCTFail("started on an unreadable key") }
        XCTAssertEqual(unreadable as? SessionCredential.Refusal, .keychainUnreadable)

        XCTAssertEqual(keychain.readsOnMain, [false, false, false], "the keychain was read on the main thread")
    }

    @MainActor
    func testTheKeychainIsNeverReadOnTheMainThreadOnceTheShellHasAnswered() async {
        let keychain = FakeKeychain()
        keychain.put("sk-saved")
        let keychainAnswers = DispatchSemaphore(value: 0)
        let lookup = KeyLookup(readShell: { nil }, readSaved: {
            keychainAnswers.wait()
            return keychain.saved.reading()
        })
        _ = await lookup.shellKey()

        let started = expectation(description: "started")
        let began = Date()
        lookup.withKey(hostTakesKey: true) { result in
            XCTAssertEqual(try? result.get(), "sk-saved")
            started.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "the main thread waited on the keychain")
        keychainAnswers.signal()
        await fulfillment(of: [started], timeout: 5)
        XCTAssertEqual(keychain.readsOnMain, [false])
    }

    @MainActor
    func testAStartNeverWaitsOnTheMainThreadForASlowShell() async {
        let shellAnswers = DispatchSemaphore(value: 0)
        let reads = Lock(0)
        let lookup = KeyLookup(
            readShell: {
                reads.withLock { $0 += 1 }
                shellAnswers.wait()
                return nil
            },
            readSaved: { .found("sk-saved") }
        )
        let first = expectation(description: "first start")
        let second = expectation(description: "second start")
        let keys = Lock<[String?]>([])

        let began = Date()
        lookup.withKey(hostTakesKey: true) { result in
            keys.withLock { $0.append(try? result.get()) }
            first.fulfill()
        }
        lookup.withKey(hostTakesKey: true) { result in
            keys.withLock { $0.append(try? result.get()) }
            second.fulfill()
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 0.5, "the main thread waited on the shell")
        XCTAssertTrue(keys.value.isEmpty)

        shellAnswers.signal()
        await fulfillment(of: [first, second], timeout: 5)
        XCTAssertEqual(keys.value, ["sk-saved", "sk-saved"])
        XCTAssertEqual(reads.value, 1, "two starts during one read share it")
    }

    @MainActor
    func testARefusalArrivesAfterTheCallerHasHeldItsPlace() async {
        let lookup = KeyLookup(readShell: { nil }, readSaved: { .missing })
        lookup.prepare()
        _ = await lookup.shellKey()

        let refused = expectation(description: "refused")
        let heldPlace = Lock(false)
        lookup.withKey(hostTakesKey: true) { result in
            XCTAssertTrue(heldPlace.value, "the refusal came before the caller returned")
            if case .failure(let error) = result {
                XCTAssertEqual(error as? SessionCredential.Refusal, .noKey)
            } else {
                XCTFail("a start with no key was handed one")
            }
            refused.fulfill()
        }
        heldPlace.value = true
        await fulfillment(of: [refused], timeout: 5)
    }
}
