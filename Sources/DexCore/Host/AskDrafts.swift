import Foundation

/// What has been written into a run of questions and not yet sent.
///
/// Held outside the card for the reason the composer's drafts are held outside
/// the field: the card is drawn per session, so looking at another session and
/// coming back builds a new one, and answers kept in its own state would go
/// with the old one — a typed answer lost to a move made to read something.
public struct AskDrafts: Equatable, Sendable {

    /// One question's worth. Keyed by the page rather than the question, which
    /// carries the ask with it: two asks can word a question the same way.
    public struct Entry: Equatable, Sendable {
        public var picked: Set<String> = []
        public var typed = ""
        public var isWritingOwn = false
        public var note = ""
        public var isNoting = false

        public init() {}

        /// An answer written and then emptied is nothing to keep, but a field
        /// opened and left blank is: the card draws it from here, and one that
        /// closed itself the moment it was cleared would take the caret with it.
        var isEmpty: Bool {
            picked.isEmpty && typed.isEmpty && note.isEmpty && !isWritingOwn && !isNoting
        }
    }

    private var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }

    public var pages: Set<String> { Set(entries.keys) }

    public subscript(pageID: String) -> Entry {
        get { entries[pageID] ?? Entry() }
        set { entries[pageID] = newValue.isEmpty ? nil : newValue }
    }

    /// Drops what belongs to questions nobody is being asked any more.
    ///
    /// Measured against every ask the host is holding rather than against one
    /// card's pages: a card shows one session's questions, and pruning to what
    /// it draws would throw away what was written into another session's.
    public mutating func keep(_ pages: [AskPage]) {
        let live = Set(pages.map(\.id))
        entries = entries.filter { live.contains($0.key) }
    }
}
