import Foundation

/// A Linear issue named in a message. The message carries its identifier and
/// URL; the session reads the rest with whatever Linear tools it has.
public struct LinearIssueMention: Mentionable {
    public let identifier: String
    public let title: String
    public let url: String
    public let stateName: String
    /// Linear's workflow category: `triage`, `backlog`, `unstarted`,
    /// `started`, `completed` or `canceled`.
    public let stateType: String
    public let teamName: String?

    public init(identifier: String, title: String, url: String, stateName: String,
                stateType: String, teamName: String? = nil) {
        self.identifier = identifier
        self.title = title
        self.url = url
        self.stateName = stateName
        self.stateType = stateType
        self.teamName = teamName
    }

    public var id: String { identifier }
    public var source: MentionSource { .linearIssue }

    public var isClosed: Bool { ["completed", "canceled"].contains(stateType) }

    /// What the menu shows beside the title.
    public var detail: String {
        ([identifier, stateName] + [teamName].compactMap { $0 })
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    public var line: String? {
        var line = "\(typed) refers to Linear issue \(identifier)"
        if !url.isEmpty { line += " (\(url))" }
        return line
    }
}

/// Linear's GraphQL API, as far as the `@` menu needs it: requests built here,
/// replies read here, so all of it is testable without a network.
public enum LinearIssues {

    public static let endpoint = URL(string: "https://api.linear.app/graphql")!
    static let limit = 10

    static let fields = "identifier title url state { name type } team { key name }"

    /// `ENG-123` or `eng-123`, upper-cased; nil for anything else.
    public static func identifier(in text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return trimmed.wholeMatch(of: #/[A-Z][A-Z0-9]*-[0-9]+/#) != nil ? trimmed : nil
    }

    /// The issue a linear.app URL points at. The workspace slug comes first and
    /// can look like an identifier (`acme-2`), so the component after `issue`
    /// is the one read.
    public static func identifier(fromURL text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(),
              host == "linear.app" || host.hasSuffix(".linear.app")
        else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        guard let issue = path.firstIndex(of: "issue"), issue + 1 < path.count else { return nil }
        return identifier(in: path[issue + 1])
    }

    // Requests

    /// What an empty `@` offers: open issues assigned to me, then whatever
    /// moved most recently.
    public static func recentBody() -> Data {
        body("""
            query { viewer { assignedIssues(first: \(limit), orderBy: updatedAt, \
            filter: { state: { type: { nin: ["completed", "canceled"] } } }) { nodes { \(fields) } } } \
            issues(first: \(limit), orderBy: updatedAt) { nodes { \(fields) } } }
            """)
    }

    /// Issues whose title has every word of the query in it, most recently
    /// updated first. A bare number also matches the issue with that number.
    public static func searchBody(for query: String) -> Data {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var filter: [String: Any] = [
            "and": words.map { ["title": ["containsIgnoreCase": $0]] }
        ]
        if words.count == 1, let number = Int(words[0]) {
            filter = ["or": [filter, ["number": ["eq": number]]]]
        }
        return body("""
            query Search($filter: IssueFilter!) { \
            issues(first: \(limit), orderBy: updatedAt, filter: $filter) { nodes { \(fields) } } }
            """, variables: ["filter": filter])
    }

    public static func issueBody(identifier: String) -> Data {
        body("query Issue($id: String!) { issue(id: $id) { \(fields) } }",
             variables: ["id": identifier])
    }

    public static func viewerBody() -> Data {
        body("query { viewer { name email } }")
    }

    /// Personal API keys go in bare; only OAuth tokens take "Bearer".
    public static func request(_ body: Data, key: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "Authorization")
        request.httpBody = body
        request.timeoutInterval = 15
        return request
    }

    private static func body(_ query: String, variables: [String: Any]? = nil) -> Data {
        var root: [String: Any] = ["query": query]
        if let variables { root["variables"] = variables }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    // Replies

    public static func parseRecent(_ data: Data) throws -> [LinearIssueMention] {
        let payload = try self.payload(data, status: nil)
        let viewer = payload["viewer"] as? [String: Any]
        let assigned = nodes(viewer?["assignedIssues"])
        let recent = nodes(payload["issues"])
        return Array(unique(assigned + recent).prefix(limit))
    }

    public static func parseSearch(_ data: Data) throws -> [LinearIssueMention] {
        unique(nodes(try payload(data, status: nil)["issues"]))
    }

    /// Nil for an issue that doesn't exist or can't be seen. Linear answers
    /// those with an error and no data, which is not the key failing.
    public static func parseIssue(_ data: Data) throws -> LinearIssueMention? {
        do {
            return issue(try payload(data, status: nil)["issue"])
        } catch LinkedServiceError.api {
            return nil
        }
    }

    public static func parseViewer(_ data: Data) throws -> String? {
        let viewer = try payload(data, status: nil)["viewer"] as? [String: Any]
        return viewer?["name"] as? String ?? viewer?["email"] as? String
    }

    /// `data`, or why there isn't any. An unauthenticated request can come
    /// back 400 with the reason only in `errors`.
    static func payload(_ data: Data, status: Int?) throws -> [String: Any] {
        if status == 401 { throw LinkedServiceError.unauthorized }
        if status == 429 { throw LinkedServiceError.rateLimited }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            if let status, status >= 400 { throw LinkedServiceError.status(status) }
            throw LinkedServiceError.unreadable
        }
        let errors = root["errors"] as? [[String: Any]] ?? []
        let codes = errors.compactMap { ($0["extensions"] as? [String: Any])?["code"] as? String }
        if codes.contains("AUTHENTICATION_ERROR") { throw LinkedServiceError.unauthorized }
        if codes.contains("RATELIMITED") { throw LinkedServiceError.rateLimited }
        guard let payload = root["data"] as? [String: Any] else {
            if let message = errors.first?["message"] as? String { throw LinkedServiceError.api(message) }
            if let status, status >= 400 { throw LinkedServiceError.status(status) }
            throw LinkedServiceError.unreadable
        }
        return payload
    }

    private static func nodes(_ connection: Any?) -> [LinearIssueMention] {
        let nodes = (connection as? [String: Any])?["nodes"] as? [Any] ?? []
        return nodes.compactMap(issue)
    }

    private static func issue(_ node: Any?) -> LinearIssueMention? {
        guard let node = node as? [String: Any],
              let identifier = node["identifier"] as? String,
              let title = node["title"] as? String, !title.isEmpty
        else { return nil }
        let state = node["state"] as? [String: Any]
        let team = node["team"] as? [String: Any]
        return LinearIssueMention(
            identifier: identifier.uppercased(),
            title: title,
            url: node["url"] as? String ?? "",
            stateName: state?["name"] as? String ?? "",
            stateType: state?["type"] as? String ?? "",
            teamName: team?["name"] as? String ?? team?["key"] as? String)
    }

    static func unique(_ issues: [LinearIssueMention]) -> [LinearIssueMention] {
        var seen = Set<String>()
        return issues.filter { seen.insert($0.identifier).inserted }
    }
}
