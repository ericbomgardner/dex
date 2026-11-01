import XCTest
@testable import DexUI
@testable import DexCore

/// A value that won't decode reads as nothing saved, and the next write goes
/// over its key, so what was there has to be kept somewhere first.
final class DefaultsDecodeTests: XCTestCase {

    private func store() throws -> UserDefaults {
        let name = "DefaultsDecodeTests-\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return store
    }

    func testAValueThatWontDecodeIsKeptPastTheNextWrite() throws {
        let store = try store()
        let unreadable = Data("[1, 2]".utf8)
        store.set(unreadable, forKey: "hostedArchive")

        XCTAssertNil(Defaults.decoded(HostedArchive.self, "hostedArchive", in: store))
        Defaults.encode(HostedArchive(), "hostedArchive", in: store)

        XCTAssertNotNil(Defaults.decoded(HostedArchive.self, "hostedArchive", in: store))
        XCTAssertEqual(store.array(forKey: Defaults.unreadableKey("hostedArchive")) as? [Data], [unreadable])
    }

    func testReadingTheSameBadValueAgainKeepsOneCopy() throws {
        let store = try store()
        let first = Data("one".utf8), second = Data("two".utf8)
        store.set(first, forKey: "sessionResolutions")
        _ = Defaults.decoded(SessionResolutions.self, "sessionResolutions", in: store)
        _ = Defaults.decoded(SessionResolutions.self, "sessionResolutions", in: store)
        store.set(second, forKey: "sessionResolutions")
        _ = Defaults.decoded(SessionResolutions.self, "sessionResolutions", in: store)

        XCTAssertEqual(store.array(forKey: Defaults.unreadableKey("sessionResolutions")) as? [Data], [first, second])
    }

    func testAGoodValueLeavesNothingAside() throws {
        let store = try store()
        Defaults.encode(SessionResolutions(), "sessionResolutions", in: store)
        XCTAssertNotNil(Defaults.decoded(SessionResolutions.self, "sessionResolutions", in: store))
        XCTAssertNil(store.object(forKey: Defaults.unreadableKey("sessionResolutions")))
    }
}
