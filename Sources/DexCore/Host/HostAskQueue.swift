import Foundation

/// The asks a session is holding out.
///
/// A turn can raise several at once — three in the first run that caught it —
/// and the terminal never shows this because its screen only holds one. They are
/// laid end to end and answered together, so there is no cursor here: which of
/// them is being read is the card's business, and an ask stays on the list until
/// it is answered or withdrawn.
public struct HostAskQueue: Equatable, Sendable {

    public private(set) var pending: [HostAsk] = []

    public init() {}

    public var count: Int { pending.count }
    public var isEmpty: Bool { pending.isEmpty }

    public func pending(forKey key: String) -> [HostAsk] {
        pending.filter { $0.key == key }
    }

    public mutating func received(_ ask: HostAsk) {
        guard !pending.contains(where: { $0.askId == ask.askId }) else { return }
        // Appended rather than inserted: a second ask arriving must not move the
        // pages out from under someone mid-read.
        pending.append(ask)
    }

    /// Answered or withdrawn — both mean the session is no longer holding it.
    @discardableResult
    public mutating func resolved(_ askId: String) -> Bool {
        guard let removed = pending.firstIndex(where: { $0.askId == askId }) else { return false }
        pending.remove(at: removed)
        return true
    }

    /// A session going away takes its asks with it; the rest belong to other
    /// sessions and stay up.
    public mutating func dropAll(forKey key: String) {
        pending.removeAll { $0.key == key }
    }

    public mutating func removeAll() {
        pending.removeAll()
    }
}
