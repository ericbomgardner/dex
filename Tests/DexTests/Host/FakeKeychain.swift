import Foundation
import Security
@testable import DexCore

/// The keychain calls `AppKeychain` makes, answered from memory. A refused
/// item answers every call with that status, as a locked keychain or a denied
/// prompt would.
final class FakeKeychain: Sendable {
    private struct State {
        var items: [String: Data] = [:]
        var refusing: [String: OSStatus] = [:]
        var readsOnMain: [Bool] = []
    }

    private let state = Lock(State())
    private static let item = "com.example.dex." + SavedAPIKey.name

    var saved: SavedAPIKey {
        SavedAPIKey(store: AppKeychain(servicePrefix: "com.example.dex", backend: backend))
    }

    var apiKey: String? {
        state.withLock { $0.items[Self.item] }.flatMap { String(data: $0, encoding: .utf8) }
    }

    /// For each read, whether it was made on the main thread.
    var readsOnMain: [Bool] { state.withLock { $0.readsOnMain } }

    func put(_ key: String) {
        state.withLock { $0.items[Self.item] = Data(key.utf8) }
    }

    func refuse(_ status: OSStatus) {
        state.withLock { $0.refusing[Self.item] = status }
    }

    private var backend: KeychainCalls {
        KeychainCalls(
            copy: { query in
                let name = query[kSecAttrService as String] as? String ?? ""
                let onMain = Thread.isMainThread
                return self.state.withLock { state in
                    state.readsOnMain.append(onMain)
                    if let status = state.refusing[name] { return (status, nil) }
                    guard let data = state.items[name] else { return (errSecItemNotFound, nil) }
                    return (errSecSuccess, data)
                }
            },
            add: { query in
                let name = query[kSecAttrService as String] as? String ?? ""
                let data = query[kSecValueData as String] as? Data
                return self.state.withLock { state in
                    if state.refusing[name] != nil || state.items[name] != nil { return errSecDuplicateItem }
                    state.items[name] = data
                    return errSecSuccess
                }
            },
            delete: { query in
                let name = query[kSecAttrService as String] as? String ?? ""
                return self.state.withLock { state in
                    if let status = state.refusing[name] { return status }
                    return state.items.removeValue(forKey: name) == nil ? errSecItemNotFound : errSecSuccess
                }
            }
        )
    }
}
