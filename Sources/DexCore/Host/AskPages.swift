import Foundation

/// One question, and which ask it has to be sent back to.
///
/// A turn can raise several asks and each carries up to four questions, but they
/// are answered in one go at the end rather than a card at a time — so what is
/// paged through is the questions themselves, laid end to end, and the ask a
/// question came from matters only when the answers are addressed back to it.
public enum AskPage: Equatable, Sendable, Identifiable {
    case question(askId: String, HostQuestion)
    case permission(askId: String, HostPermissionRequest)

    public var askId: String {
        switch self {
        case .question(let askId, _), .permission(let askId, _): askId
        }
    }

    /// The ask is part of the identity because two of them can word a question
    /// the same way, and an answer filed under the text alone would be read as
    /// belonging to both.
    public var id: String {
        switch self {
        case .question(let askId, let question): "\(askId)\u{0}\(question.question)"
        case .permission(let askId, _): askId
        }
    }

    public var question: HostQuestion? {
        if case .question(_, let question) = self { return question }
        return nil
    }

    public var permission: HostPermissionRequest? {
        if case .permission(_, let request) = self { return request }
        return nil
    }
}

public enum AskPages {
    /// One page per question, and one for a permission, which has nothing to
    /// page through.
    public static func read(_ asks: [HostAsk]) -> [AskPage] {
        asks.flatMap { ask -> [AskPage] in
            switch HostAskContent.read(ask) {
            case .questions(let questions):
                questions.map { .question(askId: ask.askId, $0) }
            case .permission(let request):
                [.permission(askId: ask.askId, request)]
            }
        }
    }

    /// The ask a page belongs to, for anything outside the card that has to
    /// address the page being read rather than the run as a whole — the
    /// composer's free text, which answers the question in front of you and not
    /// whichever ask has been waiting longest.
    public static func owner(of pageID: String, in asks: [HostAsk]) -> HostAsk? {
        asks.first { ask in read([ask]).contains { $0.id == pageID } }
    }
}
