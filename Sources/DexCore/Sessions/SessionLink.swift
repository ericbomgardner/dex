import Foundation

/// `dex://session/<id>?name=…&cwd=…`, what "Copy Link to Session"
/// puts on the pasteboard. The name and folder ride along because whatever
/// the link is pasted into can't ask Dex for them.
public struct SessionLink: Equatable, Sendable {
    public static let scheme = "dex"

    public let sessionID: String
    public var name: String?
    public var cwd: String?

    public init(
        sessionID: String, name: String? = nil, cwd: String? = nil
    ) {
        self.sessionID = sessionID
        self.name = name
        self.cwd = cwd
    }

    public var url: URL { url(scheme: Self.scheme) }

    public func url(scheme: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "session"
        components.path = "/" + sessionID
        let items = [
            ("name", name), ("cwd", cwd),
        ]
            .compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        components.queryItems = items.isEmpty ? nil : items
        return components.url!
    }

    public init?(url: URL, scheme: String = Self.scheme) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme == scheme, components.host == "session"
        else { return nil }
        let id = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty, !id.contains("/") else { return nil }
        func value(_ key: String) -> String? {
            components.queryItems?.first { $0.name == key }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        self.init(
            sessionID: id, name: value("name"), cwd: value("cwd")
        )
    }

    /// Pasted text read as one link.
    public init?(pasted text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace), let url = URL(string: trimmed) else { return nil }
        guard let link = SessionLink(url: url) else { return nil }
        self = link
    }
}
