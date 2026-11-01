import Foundation

/// A session named in a message by its title. The title is what was typed and
/// what the model reads in the sentence; the id and transcript ride under the
/// message as a line of their own, since a title is nothing a session can open.
public struct SessionMention: Mentionable {
    public let title: String
    public let sessionID: String
    public let rowID: String

    /// Where it ran, for telling two sessions of the same name apart in the menu.
    public let folder: String

    /// Filled in at send, off disk; nil until then and for a session whose file
    /// this Mac cannot see.
    public var transcript: String?

    /// Resolved in the list, which the menu says beside the folder. Not kept
    /// with a draft: by the time it's read back, it may no longer be true.
    public var isResolved = false

    private enum CodingKeys: String, CodingKey {
        case title, sessionID, rowID, folder, transcript
    }

    public init(title: String, sessionID: String, rowID: String, folder: String,
                transcript: String? = nil, isResolved: Bool = false) {
        self.title = title
        self.sessionID = sessionID
        self.rowID = rowID
        self.folder = folder
        self.transcript = transcript
        self.isResolved = isResolved
    }

    /// A session named by a pasted link, which may be one the list doesn't
    /// hold.
    public init?(_ link: SessionLink) {
        let folder = link.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        self.init(title: link.name ?? "Session \(link.sessionID.prefix(8))", sessionID: link.sessionID,
                  rowID: link.sessionID, folder: folder)
    }

    public var id: String { rowID }
    public var source: MentionSource { .dexSession }
    public var detail: String {
        guard isResolved else { return folder }
        return folder.isEmpty ? "resolved" : folder + " · resolved"
    }

    /// The line under the message that says what the name stands for.
    public var line: String? {
        var line = "\(typed) refers to session `\(sessionID)`"
        if let transcript { line += " (transcript: `\(transcript)`)" }
        return line
    }

    public func located(by locate: (String) -> String?) -> SessionMention {
        var found = self
        found.transcript = locate(sessionID)
        return found
    }
}

/// What the composer offers while a title is being typed after an `@`, and what
/// the message carries for it once sent.
public enum SessionMentions {

    /// Longer than any title, so a stretch of prose that happens to follow an
    /// `@` stops being read as a name being typed.
    static let longestQuery = 80

    /// The text after the `@` a name is being typed at: the last one in the
    /// draft that starts a word, or opens a bracket or quote. Nil once the line
    /// breaks, or the text runs on past any title, or the `@` is inside a word
    /// — an address, a handle.
    public static func query(in draft: String) -> String? {
        guard let at = draft.lastIndex(of: "@") else { return nil }
        if at > draft.startIndex {
            let before = draft[draft.index(before: at)]
            guard before.isWhitespace || "([{\"'\u{201C}\u{2018}".contains(before) else { return nil }
        }

        let typed = draft[draft.index(after: at)...]
        guard typed.count <= longestQuery,
              !typed.contains(where: \.isNewline),
              typed.first?.isWhitespace != true
        else { return nil }
        return String(typed)
    }

    /// The rows worth naming: ones with a title, a transcript, and a file on
    /// this Mac.
    public static func candidates(
        in rows: [SessionRowModel],
        excluding rowID: String? = nil,
        resolved: Bool = false
    ) -> [SessionMention] {
        rows.compactMap { row in
            guard row.rowID != rowID,
                  let title = row.session.chosenName,
                  let sessionID = row.session.sessionId, !sessionID.isEmpty
            else { return nil }
            return SessionMention(title: title, sessionID: sessionID,
                                  rowID: row.rowID, folder: row.session.folderName, isResolved: resolved)
        }
    }

    /// Ordered as the list is where the query says nothing, since the row you
    /// mean is most often the one you just looked at.
    public static func matches<M: Mentionable>(
        for draft: String,
        in candidates: [M],
        limit: Int = 6
    ) -> [M] {
        guard let query = query(in: draft) else { return [] }
        guard !query.isEmpty else { return Array(candidates.prefix(limit)) }

        let scored = candidates.enumerated().compactMap { index, mention -> (M, Int, Int)? in
            guard let match = FuzzyMatch.match(query, in: mention.title) else { return nil }
            return (mention, match.score, index)
        }

        return scored
            .sorted { left, right in
                let leading = (starts(left.0, with: query), starts(right.0, with: query))
                if leading.0 != leading.1 { return leading.0 }
                if left.1 != right.1 { return left.1 > right.1 }
                return left.2 < right.2
            }
            .prefix(limit)
            .map(\.0)
    }

    /// The draft with the name typed out in place of what was typed so far, and
    /// a space after it for the sentence to go on.
    public static func accepting(_ mention: some Mentionable, in draft: String) -> String {
        guard query(in: draft) != nil, let at = draft.lastIndex(of: "@") else { return draft }
        return String(draft[..<at]) + mention.typed + " "
    }

    /// Which sessions a draft names, in the order it names them. A pick whose
    /// title was since deleted from the text is dropped; a title typed out by
    /// hand, or one whose pick was lost with the view that held it, still
    /// resolves against what the list knows.
    public static func resolved<M: Mentionable>(
        in draft: String,
        picked: [M],
        known: [M]
    ) -> [M] {
        var seen = Set<String>()
        var claimed: [Range<String.Index>] = []
        return (picked + known)
            .filter { seen.insert($0.id).inserted }
            // Longest first, so a title that is the start of a longer one —
            // `@Fix the sidebar` against `@Fix the sidebar fixtures` — reads
            // as the longer one where the text says the longer one.
            .sorted { $0.title.count > $1.title.count }
            .compactMap { mention -> (M, String.Index)? in
                guard let range = named(mention, in: draft, outside: claimed) else { return nil }
                claimed.append(range)
                return (mention, range.lowerBound)
            }
            .sorted { $0.1 < $1.1 }
            .map(\.0)
    }

    /// Where the draft names the session, if it does: the title, ending where a
    /// word ends, somewhere no longer title has already been read.
    private static func named(
        _ mention: some Mentionable,
        in draft: String,
        outside claimed: [Range<String.Index>]
    ) -> Range<String.Index>? {
        var from = draft.startIndex
        while let range = draft.range(of: mention.typed, range: from..<draft.endIndex) {
            from = range.upperBound
            let next = range.upperBound < draft.endIndex ? draft[range.upperBound] : nil
            if next?.isLetter == true || next?.isNumber == true { continue }
            if claimed.contains(where: { $0.overlaps(range) }) { continue }
            return range
        }
        return nil
    }

    private static func starts(_ mention: some Mentionable, with query: String) -> Bool {
        mention.title.lowercased().hasPrefix(query.lowercased())
    }
}
