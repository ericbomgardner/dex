import Foundation
import Security
import XCTest
@testable import DexCore

final class AppKeychainTests: XCTestCase {

    private final class Fake: @unchecked Sendable {
        var items: [String: Data] = [:]
        var labels: [String: String] = [:]
        var calls: [[String: Any]] = []
        /// Items an earlier build saved, with what this one is told when it
        /// asks for or deletes them. Nothing this build does changes that.
        var foreign: [String: OSStatus] = [:]

        func key(_ query: [String: Any]) -> String {
            (query[kSecAttrService as String] as? String ?? "") + "#" + (query[kSecAttrAccount as String] as? String ?? "")
        }

        var backend: KeychainCalls {
            KeychainCalls(
                copy: { query in
                    self.calls.append(query)
                    if let status = self.foreign[self.key(query)] { return (status, nil) }
                    guard let data = self.items[self.key(query)] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data)
                },
                add: { query in
                    self.calls.append(query)
                    if self.items[self.key(query)] != nil || self.foreign[self.key(query)] != nil { return errSecDuplicateItem }
                    self.items[self.key(query)] = query[kSecValueData as String] as? Data
                    self.labels[self.key(query)] = query[kSecAttrLabel as String] as? String
                    return errSecSuccess
                },
                delete: { query in
                    self.calls.append(query)
                    if self.foreign[self.key(query)] != nil { return errSecAuthFailed }
                    return self.items.removeValue(forKey: self.key(query)) == nil ? errSecItemNotFound : errSecSuccess
                }
            )
        }
    }

    private let fake = Fake()
    private var store: AppKeychain { AppKeychain(servicePrefix: "com.example.dex", backend: fake.backend) }

    func testATokenRoundTripsUnderTheAppsOwnService() throws {
        XCTAssertNil(store.read("linear"))
        try store.save("lin_api_1", as: "linear", label: "Dex Linear token")
        XCTAssertEqual(store.read("linear"), "lin_api_1")
        XCTAssertEqual(fake.items["com.example.dex.linear#token"], Data("lin_api_1".utf8))
        XCTAssertEqual(fake.labels["com.example.dex.linear#token"], "Dex Linear token")
        XCTAssertNil(store.read("notion"))
    }

    func testSavingAgainReplacesTheToken() throws {
        try store.save("old", as: "slack", label: "Dex Slack token")
        try store.save("new", as: "slack", label: "Dex Slack token")
        XCTAssertEqual(store.read("slack"), "new")
    }

    func testNilOrEmptyRemovesTheToken() throws {
        try store.save("t", as: "notion", label: "Dex Notion token")
        try store.save(nil, as: "notion", label: "Dex Notion token")
        XCTAssertNil(store.read("notion"))
        try store.save("t", as: "notion", label: "Dex Notion token")
        try store.save("", as: "notion", label: "Dex Notion token")
        XCTAssertNil(store.read("notion"))
        XCTAssertTrue(fake.items.isEmpty)
        try store.save(nil, as: "notion", label: "Dex Notion token")
    }

    /// No group, no data-protection keychain and no access list: what an ad
    /// hoc signed build can do.
    func testItemsAskForNothingAnAdHocBuildCantHave() throws {
        try store.save("t", as: "linear", label: "Dex Linear token")
        _ = store.read("linear")
        XCTAssertFalse(fake.calls.isEmpty)
        for call in fake.calls {
            XCTAssertNil(call[kSecAttrAccessGroup as String])
            XCTAssertNil(call[kSecUseDataProtectionKeychain as String])
            XCTAssertNil(call[kSecAttrAccess as String])
            XCTAssertNil(call[kSecAttrAccessControl as String])
            XCTAssertEqual(call[kSecClass as String] as? String, kSecClassGenericPassword as String)
        }
    }

    // What the keychain wouldn't give up

    func testARefusedReadIsUnreadableNotMissing() {
        for status in [errSecAuthFailed, errSecInteractionNotAllowed, errSecUserCanceled] {
            fake.foreign["com.example.dex.linear#token"] = status
            XCTAssertEqual(store.reading("linear"), .unreadable(status))
            XCTAssertNil(store.read("linear"))
        }
        XCTAssertEqual(store.reading("notion"), .missing)
    }

    func testAnEmptyItemIsMissing() {
        fake.items["com.example.dex.slack#token"] = Data()
        XCTAssertEqual(store.reading("slack"), .missing)
    }

    /// A differently signed build's item: this one can't delete it, and writing
    /// over it would leave it as unreadable as before.
    func testAnItemThisBuildCantDeleteSaysWhatToDo() {
        fake.foreign["com.example.dex.linear#token"] = errSecAuthFailed
        for value in ["new", nil] {
            XCTAssertThrowsError(try store.save(value, as: "linear", label: "Dex Linear token")) {
                XCTAssertEqual($0 as? TokenNotReplaced, TokenNotReplaced(label: "Dex Linear token", status: errSecAuthFailed))
                XCTAssertTrue($0.localizedDescription.contains("Keychain Access"))
            }
            XCTAssertEqual(store.reading("linear"), .unreadable(errSecAuthFailed))
        }
    }

    /// Off by default: the real login keychain can ask for a password.
    func testTheRealKeychain() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DEX_KEYCHAIN_TESTS"] == "1",
                          "set DEX_KEYCHAIN_TESTS=1 to use the login keychain")
        let real = AppKeychain(servicePrefix: "com.example.dex-test.\(UUID().uuidString)")
        defer { try? real.save(nil, as: "linear", label: "") }
        try real.save("lin_api_real", as: "linear", label: "Dex test token")
        XCTAssertEqual(real.read("linear"), "lin_api_real")
        try real.save(nil, as: "linear", label: "")
        XCTAssertNil(real.read("linear"))
    }
}
