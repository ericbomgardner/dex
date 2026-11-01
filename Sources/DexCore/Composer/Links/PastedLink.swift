import Foundation

/// A URL the composer turns into a chip when it is pasted on its own: a Slack
/// message, thread or channel, a GitHub pull request or issue, a Linear issue,
/// or a Notion page. Anything else pastes as text.
public enum PastedLink: Hashable, Sendable, Codable {
    case slack(SlackLink)
    case github(GitHubLink)
    case linear(LinearLink)
    case notion(NotionLink)

    public enum Service: String, Hashable, Sendable, CaseIterable {
        case slack, github, linear, notion
    }

    /// The pasted text read as one link: a single http(s) URL and nothing else
    /// but the whitespace around it.
    public init?(pasted text: String) {
        self.init(url: text)
    }

    public init?(url input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.contains(where: \.isWhitespace),
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let path = components.path.split(separator: "/").map(String.init)
        let query = components.queryItems ?? []

        if let link = SlackLink(url: trimmed, host: host, path: path, query: query) {
            self = .slack(link)
        } else if let link = GitHubLink(url: trimmed, host: host, path: path) {
            self = .github(link)
        } else if let link = LinearLink(url: trimmed, host: host, path: path) {
            self = .linear(link)
        } else if let link = NotionLink(url: trimmed, host: host, path: path, query: query) {
            self = .notion(link)
        } else {
            return nil
        }
    }

    public var service: Service {
        switch self {
        case .slack: .slack
        case .github: .github
        case .linear: .linear
        case .notion: .notion
        }
    }

    /// The URL as it was pasted, trimmed. This is what the message carries.
    public var url: String {
        switch self {
        case .slack(let link): link.url
        case .github(let link): link.url
        case .linear(let link): link.url
        case .notion(let link): link.url
        }
    }

    /// What a chip says before, or without, a lookup: whatever the URL itself
    /// gives away.
    public var fallbackTitle: String {
        switch self {
        case .slack(let link): link.fallbackTitle
        case .github(let link): link.reference
        case .linear(let link): link.identifier
        case .notion(let link): link.slug ?? "Notion page"
        }
    }
}

/// `https://acme.slack.com/archives/C0123/p1700000000123456?thread_ts=…` and
/// the `app.slack.com/client/T…/C…` forms the desktop client copies.
public struct SlackLink: Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable {
        case channel
        case message
        /// A reply inside a thread: `ts` is the reply, `threadTs` its parent.
        case reply
        /// A whole thread, as the client's thread view links it.
        case thread
    }

    public let url: String
    /// The subdomain of a workspace host (`acme` in `acme.slack.com`), nil for
    /// `app.slack.com`, which names the team by id instead.
    public let workspace: String?
    public let team: String?
    public let channel: String
    /// Slack's message timestamp, `1700000000.123456`.
    public let ts: String?
    public let threadTs: String?

    public var kind: Kind {
        switch (ts, threadTs) {
        case (nil, nil): .channel
        case (nil, _?): .thread
        case (_?, nil): .message
        case (_?, _?): .reply
        }
    }

    init?(url: String, host: String, path: [String], query: [URLQueryItem]) {
        guard host == "slack.com" || host.hasSuffix(".slack.com") else { return nil }
        let isApp = host == "app.slack.com"
        var team: String?
        let channel: String
        var ts: String?
        var threadTs: String?

        if let archives = path.firstIndex(of: "archives"), archives + 1 < path.count {
            channel = path[archives + 1]
            if archives + 2 < path.count {
                guard let stamp = Self.timestamp(fromPermalink: path[archives + 2]) else { return nil }
                ts = stamp
            }
        } else if path.first == "client", path.count >= 3 {
            team = path[1]
            channel = path[2]
            if path.count >= 5, path[3] == "thread" {
                let parts = path[4].split(separator: "-", maxSplits: 1).map(String.init)
                guard parts.count == 2, Self.isTimestamp(parts[1]) else { return nil }
                threadTs = parts[1]
            } else if path.count >= 4, let stamp = Self.timestamp(fromPermalink: path[3]) {
                ts = stamp
            }
        } else {
            return nil
        }
        guard channel.wholeMatch(of: #/[CDG][A-Z0-9]+/#) != nil else { return nil }

        if let asked = query.first(where: { $0.name == "thread_ts" })?.value, Self.isTimestamp(asked) {
            if ts == nil { threadTs = asked } else if asked != ts { threadTs = asked }
        }

        self.url = url
        self.workspace = isApp ? nil : Self.workspace(in: host)
        self.team = team
        self.channel = channel
        self.ts = ts
        self.threadTs = threadTs
    }

    var fallbackTitle: String {
        let what = switch kind {
        case .channel: "Slack channel"
        case .message: "Slack message"
        case .reply: "Slack thread reply"
        case .thread: "Slack thread"
        }
        guard let workspace else { return what }
        return "\(what) in \(workspace)"
    }

    /// `acme` from `acme.slack.com`, and from an Enterprise Grid host like
    /// `acme.enterprise.slack.com`.
    private static func workspace(in host: String) -> String? {
        guard host != "slack.com" else { return nil }
        return host.split(separator: ".").first.map(String.init)
    }

    /// `p1700000000123456` → `1700000000.123456`.
    static func timestamp(fromPermalink component: String) -> String? {
        guard let match = component.wholeMatch(of: #/p([0-9]{7,})/#) else { return nil }
        let digits = String(match.1)
        return "\(digits.dropLast(6)).\(digits.suffix(6))"
    }

    private static func isTimestamp(_ text: String) -> Bool {
        text.wholeMatch(of: #/[0-9]+\.[0-9]+/#) != nil
    }
}

/// A pull request or issue on github.com. Enterprise hosts aren't recognised:
/// `gh` would need to be told which host, and nothing here knows.
public struct GitHubLink: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case pull, issue
    }

    public let url: String
    public let owner: String
    public let repo: String
    public let number: Int
    public let kind: Kind

    public var reference: String { "\(owner)/\(repo)#\(number)" }

    init?(url: String, host: String, path: [String]) {
        guard host == "github.com" || host == "www.github.com", path.count >= 4 else { return nil }
        let kind: Kind
        switch path[2] {
        case "pull": kind = .pull
        case "issues": kind = .issue
        default: return nil
        }
        guard let number = Int(path[3]), number > 0,
              Self.isName(path[0]), Self.isName(path[1])
        else { return nil }
        self.url = url
        self.owner = path[0]
        self.repo = path[1]
        self.number = number
        self.kind = kind
    }

    private static func isName(_ text: String) -> Bool {
        text.wholeMatch(of: #/[A-Za-z0-9_.\-]+/#) != nil
    }
}

/// `https://linear.app/acme/issue/ENG-123/the-slug`.
public struct LinearLink: Hashable, Sendable, Codable {
    public let url: String
    public let workspace: String?
    /// `ENG-123`, upper-cased.
    public let identifier: String

    init?(url: String, host: String, path: [String]) {
        guard host == "linear.app" || host.hasSuffix(".linear.app"),
              let issue = path.firstIndex(of: "issue"), issue + 1 < path.count
        else { return nil }
        let candidate = path[issue + 1].uppercased()
        guard candidate.wholeMatch(of: #/[A-Z][A-Z0-9]*-[0-9]+/#) != nil else { return nil }
        self.url = url
        self.workspace = issue > 0 ? path[0] : nil
        self.identifier = candidate
    }
}

/// A Notion page, by the 32 hex digits at the end of its URL.
public struct NotionLink: Hashable, Sendable, Codable {
    public let url: String
    /// Without dashes.
    public let pageId: String
    /// The title the URL itself carries, if any.
    public let slug: String?

    init?(url: String, host: String, path: [String], query: [URLQueryItem]) {
        guard ["notion.so", "notion.com", "notion.site"].contains(where: { host == $0 || host.hasSuffix(".\($0)") })
        else { return nil }
        // A page opened as a peek from a database keeps the database in the
        // path and the page in `p`.
        if let peek = query.first(where: { $0.name == "p" })?.value, let page = Self.pageId(in: peek) {
            self.pageId = page.id
            self.slug = nil
        } else if let last = path.last, let page = Self.pageId(in: last) {
            self.pageId = page.id
            self.slug = Self.slug(page.before)
        } else {
            return nil
        }
        self.url = url
    }

    private static func pageId(in component: String) -> (id: String, before: String)? {
        let lower = component.lowercased()
        if let match = lower.firstMatch(of: #/([0-9a-f]{8})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{4})-([0-9a-f]{12})$/#) {
            let before = String(component.prefix(lower.distance(from: lower.startIndex, to: match.range.lowerBound)))
            return ("\(match.1)\(match.2)\(match.3)\(match.4)\(match.5)", before)
        }
        guard let match = lower.firstMatch(of: #/([0-9a-f]{32})$/#) else { return nil }
        return (String(match.1), String(component.dropLast(32)))
    }

    private static func slug(_ before: String) -> String? {
        var slug = before
        if slug.hasSuffix("-") { slug.removeLast() }
        let title = slug.replacingOccurrences(of: "-", with: " ")
            .removingPercentEncoding?.trimmingCharacters(in: .whitespaces) ?? ""
        return title.isEmpty ? nil : title
    }
}
