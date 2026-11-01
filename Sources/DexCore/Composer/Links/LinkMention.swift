import Foundation

/// What a lookup learned about a pasted link.
public struct LinkResolution: Hashable, Sendable, Codable {
    public var title: String
    /// Second line of meaning: a PR's repo and state, a message's author and channel.
    public var detail: String?
    public var state: LinkState?

    public init(title: String, detail: String? = nil, state: LinkState? = nil) {
        self.title = title
        self.detail = detail
        self.state = state
    }
}

public enum LinkState: String, Hashable, Sendable, Codable {
    case open, draft, merged, closed, done
}

/// A pasted link as a chip. The chip shows the title; the message carries
/// the link as `[title](url)` in the sentence where the chip sat, because
/// the model needs the URL itself to act on and the title to read the
/// sentence. Nothing rides under the message for it: the URL is already there.
public enum LinkMention: Mentionable {
    case slack(SlackLinkMention)
    case github(GitHubLinkMention)
    case page(PageLinkMention)

    public init(_ link: PastedLink, resolution: LinkResolution? = nil) {
        switch link {
        case .slack(let slack): self = .slack(SlackLinkMention(link: slack, resolution: resolution))
        case .github(let github): self = .github(GitHubLinkMention(link: github, resolution: resolution))
        case .linear, .notion: self = .page(PageLinkMention(link: link, resolution: resolution))
        }
    }

    private var base: any LinkMentionable {
        switch self {
        case .slack(let mention): mention
        case .github(let mention): mention
        case .page(let mention): mention
        }
    }

    public var id: String { base.id }
    public var title: String { base.title }
    public var url: String { base.url }
    public var detail: String { base.resolution?.detail ?? "" }
    public var state: LinkState? { base.resolution?.state }
    public var isResolved: Bool { base.resolution != nil }
    public var sentence: String { base.sentence }
    public var typed: String { sentence }
    public var line: String? { nil }

    public var source: MentionSource {
        switch service {
        case .slack: .slack
        case .github: .github
        case .linear: .linearIssue
        case .notion: .notionPage
        }
    }

    public var service: PastedLink.Service {
        switch self {
        case .slack: .slack
        case .github: .github
        case .page(let page): page.link.service
        }
    }
}

/// What every link mention has: its URL, and what a lookup said about it.
public protocol LinkMentionable: Mentionable {
    var url: String { get }
    var resolution: LinkResolution? { get }
}

extension LinkMentionable {
    public var id: String { url }
    public var detail: String { resolution?.detail ?? "" }
    public var typed: String { sentence }
    public var line: String? { nil }
    public var isResolved: Bool { resolution != nil }
    public var sentence: String { LinkSentence.markdown(title: title, url: url) }
}

public struct SlackLinkMention: LinkMentionable {
    public let link: SlackLink
    public var resolution: LinkResolution?

    public init(link: SlackLink, resolution: LinkResolution? = nil) {
        self.link = link
        self.resolution = resolution
    }

    public var url: String { link.url }
    public var title: String { resolution?.title ?? link.fallbackTitle }
    public var source: MentionSource { .slack }
}

public struct GitHubLinkMention: LinkMentionable {
    public let link: GitHubLink
    public var resolution: LinkResolution?

    public init(link: GitHubLink, resolution: LinkResolution? = nil) {
        self.link = link
        self.resolution = resolution
    }

    public var url: String { link.url }
    public var title: String { resolution?.title ?? link.reference }
    public var source: MentionSource { .github }
}

/// A Linear issue or Notion page pasted by URL.
public struct PageLinkMention: LinkMentionable {
    public let link: PastedLink
    public var resolution: LinkResolution?

    public init(link: PastedLink, resolution: LinkResolution? = nil) {
        self.link = link
        self.resolution = resolution
    }

    public var url: String { link.url }
    public var title: String { resolution?.title ?? link.fallbackTitle }
    public var source: MentionSource { link.service == .linear ? .linearIssue : .notionPage }
}

public enum LinkSentence {

    /// Longer than a chip will show, short enough that a Slack message used as
    /// a title doesn't swamp the sentence it sits in.
    public static let longestTitle = 80

    /// `[title](url)`, with the title on one line and its brackets escaped, and
    /// any paren in the URL encoded so it can't end the link early.
    public static func markdown(title: String, url: String) -> String {
        "[\(escaped(shortened(title)))](\(destination(url)))"
    }

    public static func shortened(_ title: String, to limit: Int = longestTitle) -> String {
        let flat = title.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard flat.count > limit else { return flat }
        return String(flat.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func escaped(_ title: String) -> String {
        var out = ""
        for character in title {
            if character == "\\" || character == "[" || character == "]" { out.append("\\") }
            out.append(character)
        }
        return out
    }

    private static func destination(_ url: String) -> String {
        url.replacingOccurrences(of: "(", with: "%28")
            .replacingOccurrences(of: ")", with: "%29")
            .replacingOccurrences(of: " ", with: "%20")
    }
}
