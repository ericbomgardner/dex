import Foundation

/// Where a mention comes from, which is what its chip and menu row are drawn with.
public enum MentionSource: String, CaseIterable, Codable, Sendable {
    case dexSession
    case linearIssue
    case notionPage
    case slack
    case github

    /// The app whose icon stands for the source, in order of preference.
    public var bundleIdentifiers: [String] {
        switch self {
        case .dexSession: [
            BundleIdentity.code,
        ]
        case .linearIssue: ["com.linear"]
        case .notionPage: ["notion.id"]
        case .slack: ["com.tinyspeck.slackmacgap"]
        case .github: ["com.github.GitHubClient"]
        }
    }

    /// Drawn where the app isn't installed.
    public var symbol: String {
        switch self {
        case .dexSession: "text.bubble"
        case .linearIssue: "circle.dashed"
        case .notionPage: "doc.richtext"
        case .slack: "number"
        case .github: "chevron.left.forwardslash.chevron.right"
        }
    }
}

/// Anything the composer can name: typed in the sentence, and carried under the
/// message as a line the model can act on.
public protocol Mentionable: Hashable, Sendable, Codable, Identifiable where ID == String {
    var source: MentionSource { get }
    var title: String { get }

    /// What tells two of the same name apart in the menu.
    var detail: String { get }

    /// What the sentence says where the chip stands.
    var typed: String { get }

    /// What rides under the message for it; nil where the sentence says enough.
    var line: String? { get }
}

extension Mentionable {
    public var typed: String { "@" + title }
}

/// Everything a chip can stand for. A new source is a struct conforming to
/// `Mentionable` and a case here, named in `base`.
public enum Mention: Mentionable {
    case session(SessionMention)
    case linear(LinearIssueMention)
    case notion(NotionPageMention)
    case link(LinkMention)

    public var base: any Mentionable {
        switch self {
        case .session(let session): session
        case .linear(let issue): issue
        case .notion(let page): page
        case .link(let link): link
        }
    }

    public var id: String { source.rawValue + ":" + base.id }
    public var source: MentionSource { base.source }
    public var title: String { base.title }
    public var detail: String { base.detail }
    public var typed: String { base.typed }
    public var line: String? { base.line }

    /// Finished with: a done or cancelled issue, a closed link.
    public var isClosed: Bool {
        switch self {
        case .linear(let issue): issue.isClosed
        case .link(let link): link.state == .done || link.state == .closed
        default: false
        }
    }

    /// A pasted link whose lookup hasn't answered yet.
    public var isPending: Bool {
        if case .link(let link) = self { return !link.isResolved }
        return false
    }

    public func located(by locate: (String) -> String?) -> Mention {
        guard case .session(let session) = self else { return self }
        return .session(session.located(by: locate))
    }
}
