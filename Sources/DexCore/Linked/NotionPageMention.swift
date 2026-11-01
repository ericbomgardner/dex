import Foundation

/// A Notion page named in a message. The message carries its URL; the session
/// reads the page with whatever Notion tools it has.
public struct NotionPageMention: Mentionable {
    /// 32 hex digits, no dashes.
    public let pageID: String
    public let title: String
    public let url: String
    public let emoji: String?
    public let parent: NotionParent
    /// The parent's title, once it has been looked up. Nil means not known,
    /// not that there is none.
    public var parentTitle: String?

    public init(pageID: String, title: String, url: String, emoji: String? = nil,
                parent: NotionParent = .unknown, parentTitle: String? = nil) {
        self.pageID = pageID
        self.title = title
        self.url = url
        self.emoji = emoji
        self.parent = parent
        self.parentTitle = parentTitle
    }

    public var id: String { pageID }
    public var source: MentionSource { .notionPage }

    /// What the menu shows beside the title: the page's emoji and where it sits.
    public var detail: String {
        let place: String? = switch parent {
        case .workspace: parentTitle ?? "Workspace"
        default: parentTitle
        }
        return [emoji, place].compactMap { $0 }.joined(separator: " ")
    }

    public var line: String? {
        "\(typed) refers to Notion page \(url.isEmpty ? NotionPages.dashed(pageID) : url)"
    }
}

public enum NotionParent: Hashable, Sendable, Codable {
    case workspace
    case page(String)
    case database(String)
    case unknown

    /// The id worth looking a title up for, dashes removed.
    public var lookupID: String? {
        switch self {
        case .page(let id), .database(let id): id
        case .workspace, .unknown: nil
        }
    }
}

/// Notion's REST API, as far as the `@` menu needs it: requests built here,
/// replies read here.
public enum NotionPages {

    public static let base = URL(string: "https://api.notion.com/v1/")!
    public static let version = "2022-06-28"
    static let limit = 10

    /// The page a notion.so, notion.com or notion.site URL points at. A page
    /// opened as a peek from a database keeps the database in the path and the
    /// page in `p`.
    public static func pageID(fromURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              ["notion.so", "notion.com", "notion.site"].contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else { return nil }
        if let peek = components.queryItems?.first(where: { $0.name == "p" })?.value,
           let id = trailingID(in: peek) {
            return id
        }
        return components.path.split(separator: "/").last.flatMap { trailingID(in: String($0)) }
    }

    /// The 8-4-4-4-12 form the API documents.
    public static func dashed(_ id: String) -> String {
        let chars = Array(id)
        guard chars.count == 32 else { return id }
        return [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { String(chars[$0]) }.joined(separator: "-")
    }

    static func undashed(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func trailingID(in component: String) -> String? {
        let lower = component.lowercased()
        if let match = lower.firstMatch(of: #/([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$/#) {
            return "\(match.1)\(match.2)\(match.3)\(match.4)\(match.5)"
        }
        return lower.firstMatch(of: #/([0-9a-f]{32})$/#).map { String($0.1) }
    }

    // Requests

    /// Pages only. An empty query lists the most recently edited; a query is
    /// left to Notion's own ranking.
    public static func searchRequest(for query: String, token: String) -> URLRequest {
        var root: [String: Any] = [
            "filter": ["property": "object", "value": "page"],
            "page_size": limit,
        ]
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            root["sort"] = ["direction": "descending", "timestamp": "last_edited_time"]
        } else {
            root["query"] = trimmed
        }
        var request = self.request("search", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        return request
    }

    public static func pageRequest(id: String, token: String) -> URLRequest {
        request("pages/\(dashed(id))", token: token)
    }

    public static func databaseRequest(id: String, token: String) -> URLRequest {
        request("databases/\(dashed(id))", token: token)
    }

    public static func meRequest(token: String) -> URLRequest {
        request("users/me", token: token)
    }

    private static func request(_ path: String, token: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        request.timeoutInterval = 15
        return request
    }

    // Replies

    public static func parseSearch(_ data: Data, status: Int? = nil) throws -> [NotionPageMention] {
        let results = try payload(data, status: status)["results"] as? [Any] ?? []
        return results.compactMap { page($0 as? [String: Any]) }
    }

    /// Nil for a page that doesn't exist or isn't shared with the integration,
    /// which Notion answers with a 404 of its own.
    public static func parsePage(_ data: Data, status: Int? = nil) throws -> NotionPageMention? {
        do {
            return page(try payload(data, status: status))
        } catch LinkedServiceError.api where status == 404 || status == 400 {
            return nil
        }
    }

    /// A parent's title, from `GET /v1/pages/{id}` or `/v1/databases/{id}`.
    public static func parseParentTitle(_ data: Data, status: Int? = nil) throws -> String? {
        let root = try payload(data, status: status)
        if root["object"] as? String == "database" {
            let text = plainText(root["title"])
            return text.isEmpty ? nil : text
        }
        return page(root)?.title
    }

    public static func parseMe(_ data: Data, status: Int? = nil) throws -> String? {
        let root = try payload(data, status: status)
        let bot = root["bot"] as? [String: Any]
        let workspace = bot?["workspace_name"] as? String
        let name = root["name"] as? String
        guard let name else { return workspace }
        return workspace.map { "\(name) in \($0)" } ?? name
    }

    static func payload(_ data: Data, status: Int?) throws -> [String: Any] {
        if status == 401 { throw LinkedServiceError.unauthorized }
        if status == 429 { throw LinkedServiceError.rateLimited }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if let status, status >= 400 { throw LinkedServiceError.status(status) }
            throw LinkedServiceError.unreadable
        }
        if root["object"] as? String == "error" {
            switch root["code"] as? String {
            case "unauthorized": throw LinkedServiceError.unauthorized
            case "rate_limited": throw LinkedServiceError.rateLimited
            default: throw LinkedServiceError.api(root["message"] as? String ?? "Notion returned an error")
            }
        }
        return root
    }

    static func page(_ root: [String: Any]?) -> NotionPageMention? {
        guard let root, root["object"] as? String == "page",
              let rawID = root["id"] as? String
        else { return nil }
        let properties = root["properties"] as? [String: Any] ?? [:]
        let titleProperty = properties.values
            .compactMap { $0 as? [String: Any] }
            .first { $0["type"] as? String == "title" }
        let title = plainText(titleProperty?["title"])
        let icon = root["icon"] as? [String: Any]
        return NotionPageMention(
            pageID: undashed(rawID),
            title: title.isEmpty ? "Untitled" : title,
            url: root["url"] as? String ?? "",
            emoji: icon?["type"] as? String == "emoji" ? icon?["emoji"] as? String : nil,
            parent: parent(root["parent"] as? [String: Any]))
    }

    private static func parent(_ parent: [String: Any]?) -> NotionParent {
        switch parent?["type"] as? String {
        case "workspace": .workspace
        case "page_id": (parent?["page_id"] as? String).map { .page(undashed($0)) } ?? .unknown
        case "database_id": (parent?["database_id"] as? String).map { .database(undashed($0)) } ?? .unknown
        default: .unknown
        }
    }

    private static func plainText(_ runs: Any?) -> String {
        (runs as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
