import Foundation

/// A side question and what came of it: the CLI's `/btw`, asked of a session's
/// conversation without the session ever hearing it. Nothing about it reaches
/// the transcript, so the app is the only thing holding it.
public struct Aside: Equatable, Sendable {
    public private(set) var exchanges: [SideExchange] = []
    public private(set) var pending: Pending?
    public private(set) var failure: Failure?

    public struct Pending: Equatable, Sendable {
        public let id: UUID
        public let question: String
    }

    public struct Failure: Equatable, Sendable {
        public let question: String
        public let reason: String
    }

    public init() {}

    /// What follows `/btw` in a draft — empty while nothing does yet — or nil
    /// where the draft is a message.
    public static func question(in draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/btw") else { return nil }
        let rest = trimmed.dropFirst(4)
        guard rest.isEmpty || rest.first!.isWhitespace else { return nil }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A newer question supersedes one still out: its answer is dropped when it
    /// comes, since the card has moved on.
    public mutating func ask(_ question: String) -> UUID {
        let id = UUID()
        pending = Pending(id: id, question: question)
        failure = nil
        return id
    }

    public mutating func answered(_ id: UUID, with response: String) {
        guard let pending, pending.id == id else { return }
        exchanges.append(SideExchange(question: pending.question, response: response))
        self.pending = nil
    }

    public mutating func failed(_ id: UUID, because reason: String) {
        guard let pending, pending.id == id else { return }
        failure = Failure(question: pending.question, reason: reason)
        self.pending = nil
    }

    /// The aside as a message to the session, for when it turns out to matter.
    public var quoted: String {
        exchanges
            .map { "I asked on the side: \($0.question)\n\nThe answer was:\n\($0.response)" }
            .joined(separator: "\n\n")
    }
}
