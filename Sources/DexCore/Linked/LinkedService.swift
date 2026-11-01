import Foundation

/// The two places an `@` can reach outside Dex, each read with a token of the
/// user's own.
public enum LinkedService: String, CaseIterable, Sendable, Identifiable {
    case linear
    case notion

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .linear: "Linear"
        case .notion: "Notion"
        }
    }
}

public typealias HTTPTransport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

public enum HTTP {
    public static let live: HTTPTransport = { try await URLSession.shared.data(for: $0) }
}

public enum LinkedServiceError: Error, Equatable, Sendable {
    case noToken
    case tokenUnreadable(OSStatus)
    case unauthorized
    case rateLimited
    case unreadable
    case status(Int)
    case api(String)

    public func message(for service: LinkedService) -> String {
        switch self {
        case .noToken: "No \(service.name) token."
        case .tokenUnreadable: "Couldn't read the \(service.name) token from the keychain."
        case .unauthorized: "\(service.name) refused the token."
        case .rateLimited: "\(service.name) is rate limiting; try again in a minute."
        case .unreadable: "\(service.name) sent back something unreadable."
        case .status(let code): "\(service.name) answered HTTP \(code)."
        case .api(let message): "\(service.name): \(message)"
        }
    }

    public static func message(_ error: any Error, for service: LinkedService) -> String {
        if let error = error as? LinkedServiceError { return error.message(for: service) }
        return error.localizedDescription
    }

    /// A lookup abandoned because the query moved on, which is no news about
    /// the service.
    public static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let error = error as? URLError, error.code == .cancelled { return true }
        return false
    }
}

/// How the last word from a service went, for Settings.
public enum LinkedServiceStatus: Equatable, Sendable {
    /// The token hasn't been read yet.
    case reading
    /// There may be a token, but the keychain wouldn't give it up.
    case unreadable(OSStatus)
    case noToken
    case unchecked
    case connected(as: String?, at: Date)
    case failed(String, at: Date)

    public var isTrouble: Bool {
        if case .failed = self { return true }
        return false
    }

    public var isUnreadable: Bool {
        if case .unreadable = self { return true }
        return false
    }
}

public protocol SecretStore: Sendable {
    func reading(for service: LinkedService) -> TokenReading
    func setSecret(_ value: String?, for service: LinkedService) throws
}

extension SecretStore {
    public func secret(for service: LinkedService) -> String? {
        reading(for: service).token
    }

    /// The token, or why there is none to send.
    func token(for service: LinkedService) throws -> String {
        switch reading(for: service) {
        case .found(let token): return token
        case .missing: throw LinkedServiceError.noToken
        case .unreadable(let status): throw LinkedServiceError.tokenUnreadable(status)
        }
    }
}

/// Linear and Notion tokens where `ConnectionTokens` keeps them.
public struct StoredSecrets: SecretStore {
    private let store: any TokenStore

    public init(store: any TokenStore = ConnectionTokens.store) {
        self.store = store
    }

    public func reading(for service: LinkedService) -> TokenReading {
        store.reading(service.rawValue)
    }

    public func setSecret(_ value: String?, for service: LinkedService) throws {
        try store.save(value, as: service.rawValue, label: "Dex \(service.name) token")
    }
}

/// Answers kept for a short while, so typing back over a query, or the menu
/// asking again as it redraws, costs no request.
struct ExpiringCache<Value: Sendable>: Sendable {
    let lifetime: TimeInterval
    private var entries: [String: (value: Value, at: Date)] = [:]

    init(lifetime: TimeInterval) {
        self.lifetime = lifetime
    }

    func value(for key: String, now: Date) -> Value? {
        guard let entry = entries[key], now.timeIntervalSince(entry.at) < lifetime else { return nil }
        return entry.value
    }

    mutating func store(_ value: Value, for key: String, now: Date) {
        if entries.count > 200 {
            entries = entries.filter { now.timeIntervalSince($0.value.at) < lifetime }
        }
        entries[key] = (value, now)
    }

    mutating func removeAll() {
        entries = [:]
    }
}
