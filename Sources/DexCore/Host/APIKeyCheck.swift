import Foundation

/// What Anthropic says of a key, asked once with a free request: listing one
/// model. A session would only learn it minutes in, because the CLI retries a
/// refused helper key (`docs/claude-code/api-key-over-login.md`).
public enum APIKeyCheck: Sendable, Equatable {
    case valid
    case invalid
    case unchecked(String)

    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    public static let live: Transport = { request in
        try await session.data(for: request)
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration)
    }()

    static let endpoint = URL(string: "https://api.anthropic.com/v1/models?limit=1")!

    static func request(for key: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        return request
    }

    public static func check(_ key: String, transport: Transport = live) async -> APIKeyCheck {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return .invalid }
        let response: URLResponse
        do {
            (_, response) = try await transport(request(for: key))
        } catch {
            return .unchecked(error.localizedDescription)
        }
        guard let status = (response as? HTTPURLResponse)?.statusCode else {
            return .unchecked("the answer wasn't HTTP")
        }
        switch status {
        case 200..<300: return .valid
        case 401: return .invalid
        default: return .unchecked("Anthropic answered HTTP \(status)")
        }
    }

    /// Checks the key first and saves it with `write` unless Anthropic refused
    /// it, so a refused key leaves the one already saved in place. A key that
    /// couldn't be checked is saved anyway.
    public static func save(
        _ key: String, transport: Transport = live, write: @Sendable (String) async throws -> Void
    ) async throws -> APIKeyCheck {
        let result = await check(key, transport: transport)
        if result != .invalid { try await write(key.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return result
    }

    /// The shell's key is checked once per launch. A check that couldn't reach
    /// Anthropic isn't kept, so the next look at Settings tries again.
    public static func shellKey(_ key: String, transport: Transport = live) async -> APIKeyCheck {
        if let known = shellChecks.withLock({ $0[key] }) { return known }
        let result = await check(key, transport: transport)
        if case .unchecked = result { return result }
        shellChecks.withLock { $0[key] = result }
        return result
    }

    private static let shellChecks = Lock<[String: APIKeyCheck]>([:])
}
