import Foundation

/// What an `@` query found outside Dex, and the query it answered.
public struct LinkedCandidates: Equatable, Sendable {
    public var query: String?
    public var linear: [LinearIssueMention]
    public var notion: [NotionPageMention]

    public init(query: String? = nil, linear: [LinearIssueMention] = [], notion: [NotionPageMention] = []) {
        self.query = query
        self.linear = linear
        self.notion = notion
    }

    public var isEmpty: Bool { linear.isEmpty && notion.isEmpty }

    /// A lane each, for `MentionRanking`.
    public var lanes: [[Mention]] {
        [linear.map(Mention.linear), notion.map(Mention.notion)]
    }
}
