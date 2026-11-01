import Foundation

/// A draft as the composer holds it: a string, so it is saved and restored like
/// any other, with each chip written in place as a token carrying its whole
/// mention. The field draws a token as a chip; the message reads it as what the
/// chip's `typed` says.
public enum ComposerChips {

    public enum Trigger: Sendable {
        case at
    }

    public enum Piece: Hashable, Sendable {
        case text(String)
        case chip(Mention)
    }

    static let open: Unicode.Scalar = "\u{E000}"
    static let close: Unicode.Scalar = "\u{E001}"

    /// What the field shows in a chip's place, and what menus read the draft with.
    public static let placeholder = "\u{FFFC}"

    /// Base64url, so a token has no `@`, `[[` or `/` in it for a menu to open on.
    public static func token(for mention: Mention) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(mention) else { return "" }
        let payload = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
        return String(open) + payload + String(close)
    }

    static func mention(in payload: String) -> Mention? {
        let base64 = payload
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONDecoder().decode(Mention.self, from: data)
    }

    /// A token that no longer reads as a mention, or was never closed, is dropped.
    public static func pieces(of draft: String) -> [Piece] {
        var pieces: [Piece] = []
        var text = String.UnicodeScalarView()
        var payload: String.UnicodeScalarView?

        for scalar in draft.unicodeScalars {
            if payload != nil {
                if scalar == close {
                    if let mention = mention(in: String(payload!)) {
                        if !text.isEmpty { pieces.append(.text(String(text))) }
                        text = .init()
                        pieces.append(.chip(mention))
                    }
                    payload = nil
                } else {
                    payload!.append(scalar)
                }
            } else if scalar == open {
                payload = .init()
            } else {
                text.append(scalar)
            }
        }
        if !text.isEmpty { pieces.append(.text(String(text))) }
        return pieces
    }

    public static func draft(from pieces: [Piece]) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let text): text
            case .chip(let mention): token(for: mention)
            }
        }.joined()
    }

    public static func hasChips(_ draft: String) -> Bool {
        draft.unicodeScalars.contains(open)
    }

    /// The draft as the session reads it, each chip typed out.
    public static func sentence(_ draft: String) -> String {
        guard hasChips(draft) else { return draft }
        return pieces(of: draft).map { piece in
            switch piece {
            case .text(let text): text
            case .chip(let mention): mention.typed
            }
        }.joined()
    }

    /// The draft as the field shows it, each chip one character.
    public static func visible(_ draft: String) -> String {
        guard hasChips(draft) else { return draft }
        return pieces(of: draft).map { piece in
            switch piece {
            case .text(let text): text
            case .chip: placeholder
            }
        }.joined()
    }

    public static func chips(in draft: String) -> [Mention] {
        pieces(of: draft).compactMap { piece in
            guard case .chip(let mention) = piece else { return nil }
            return mention
        }
    }

    /// What the draft names, in the order it names them: its chips, and a title
    /// typed out by hand, or left from a draft older than chips, resolved against
    /// what the list knows.
    public static func named(in draft: String, known: [Mention]) -> [Mention] {
        var seen = Set<String>()
        return pieces(of: draft)
            .flatMap { piece -> [Mention] in
                switch piece {
                case .chip(let mention): [mention]
                case .text(let text): SessionMentions.resolved(in: text, picked: [], known: known)
                }
            }
            .filter { seen.insert($0.id).inserted }
    }

    /// The draft either side of the caret, from what the field last said came
    /// before it. A head the draft no longer starts with is from before an edit,
    /// and the caret is taken to be at the end.
    public static func split(_ draft: String, at head: String?) -> (head: String, tail: String) {
        guard let head, draft.unicodeScalars.starts(with: head.unicodeScalars) else { return (draft, "") }
        return (head, String(draft.unicodeScalars.dropFirst(head.unicodeScalars.count)))
    }

    /// The draft up to the caret, for a menu to complete; empty with the caret
    /// inside a word, where taking a row would leave the rest of it behind.
    public static func completing(_ draft: String, at caret: String?) -> String {
        let (head, tail) = split(draft, at: caret)
        if let next = tail.first, next.isLetter || next.isNumber { return "" }
        return head
    }

    /// What goes between something taken from a menu and the text after the
    /// caret: a space, unless the text already has one or closes a bracket or
    /// sentence there.
    static func joiner(before tail: String) -> String {
        guard let next = tail.first else { return " " }
        return next.isWhitespace || ")]}.,;:!?".contains(next) ? "" : " "
    }

    /// The draft with what was typed after the `@` taken back out and the chip
    /// standing in for it, then a space for the sentence to go on. `caret` is
    /// the draft up to the caret, where the name was being typed; whatever
    /// follows it is kept. `after` is what opened the menu the row was taken
    /// from.
    public static func accepting(
        _ mention: Mention,
        in draft: String,
        caret: String? = nil,
        after trigger: Trigger = .at
    ) -> String {
        let (head, tail) = split(draft, at: caret)
        let shown = visible(head)
        let typing: String? = switch trigger {
        case .at: SessionMentions.query(in: shown).map { "@" + $0 }
        }
        var kept = head
        if let typing, kept.hasSuffix(typing) { kept.removeLast(typing.count) }
        return kept + token(for: mention) + joiner(before: tail) + tail
    }
}
