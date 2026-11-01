import Foundation
import Security

/// What a store held for a name when asked.
public enum TokenReading: Equatable, Sendable {
    case found(String)
    case missing
    /// There may be a token, but the keychain wouldn't hand it over: denied,
    /// locked, or a build it doesn't trust.
    case unreadable(OSStatus)

    public var token: String? {
        if case .found(let token) = self { return token }
        return nil
    }
}

/// Where a token pasted into Settings is kept, one per name. Both calls can
/// wait on a keychain prompt, so neither belongs on the main thread.
public protocol TokenStore: Sendable {
    func reading(_ name: String) -> TokenReading
    /// Nil or empty removes it.
    func save(_ value: String?, as name: String, label: String) throws
}

extension TokenStore {
    public func read(_ name: String) -> String? {
        reading(name).token
    }
}

/// Tokens as plain generic-password items in the login keychain, under the
/// app's own service names. No access group, which would tie the build to one
/// team, and the default access list, so only the app that saved an item reads
/// it without asking.
public struct AppKeychain: TokenStore {
    public static let account = "token"

    let servicePrefix: String
    let backend: KeychainCalls

    public init(servicePrefix: String = BundleIdentity.code) {
        self.init(servicePrefix: servicePrefix, backend: .live)
    }

    init(servicePrefix: String, backend: KeychainCalls) {
        self.servicePrefix = servicePrefix
        self.backend = backend
    }

    func item(_ name: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: servicePrefix + "." + name,
            kSecAttrAccount as String: Self.account,
        ]
    }

    public func reading(_ name: String) -> TokenReading {
        var query = item(name)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = backend.copy(query)
        switch status {
        case errSecSuccess:
            guard let text = data.flatMap({ String(data: $0, encoding: .utf8) }), !text.isEmpty else { return .missing }
            return .found(text)
        case errSecItemNotFound:
            return .missing
        default:
            return .unreadable(status)
        }
    }

    /// An item saved by a build signed with another certificate can refuse to
    /// be deleted by this one. Writing over it would keep that build's access
    /// list, so it would still be unreadable here; the user deletes it instead.
    public func save(_ value: String?, as name: String, label: String) throws {
        let deleted = backend.delete(item(name))
        guard deleted == errSecSuccess || deleted == errSecItemNotFound else {
            throw TokenNotReplaced(label: label, status: deleted)
        }
        guard let value, !value.isEmpty else { return }
        var query = item(name)
        query[kSecValueData as String] = Data(value.utf8)
        query[kSecAttrLabel as String] = label
        let status = backend.add(query)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }
}

/// The keychain kept an item this build isn't allowed to delete.
public struct TokenNotReplaced: Error, LocalizedError, Equatable {
    public let label: String
    public let status: OSStatus

    public var errorDescription: String? {
        "the keychain won't let Dex change \"\(label)\". Delete it in Keychain Access, then paste the token again."
    }
}

/// The Security calls, apart so what is asked of them can be tested.
struct KeychainCalls: Sendable {
    var copy: @Sendable ([String: Any]) -> (OSStatus, Data?)
    var add: @Sendable ([String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let live = KeychainCalls(
        copy: { query in
            var result: AnyObject?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        delete: { SecItemDelete($0 as CFDictionary) }
    )
}

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let text = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain: \(text)"
    }
}
