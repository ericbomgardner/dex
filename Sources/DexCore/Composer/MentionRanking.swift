import Foundation

/// Everything an `@` could offer, a lane per source. `searched` lanes are a
/// service's own answer to `searchedFor`, which matched on more than the
/// title. `resolved` are sessions done with, offered only to a typed query and
/// below everything else. The searched services are Linear and Notion.
public struct MentionCandidates: Equatable, Sendable {
    public var lanes: [[Mention]]
    public var searched: [[Mention]]
    public var searchedFor: String?
    public var resolved: [Mention]

    public init(lanes: [[Mention]] = [], searched: [[Mention]] = [], searchedFor: String? = nil,
                resolved: [Mention] = []) {
        self.lanes = lanes
        self.searched = searched
        self.searchedFor = searchedFor
        self.resolved = resolved
    }

    public var all: [Mention] {
        lanes.flatMap { $0 } + searched.flatMap { $0 }
            + resolved
    }
}

/// What an `@` query found outside Dex, a lane per service, and the query it answered.
public struct MentionSearch: Equatable, Sendable {
    public var query: String?
    public var lanes: [[Mention]]

    public init(query: String? = nil, lanes: [[Mention]] = []) {
        self.query = query
        self.lanes = lanes
    }
}

/// How the `@` menu orders its sources together.
public enum MentionRanking {

    public static let limit = 8

    /// What the menu offers for a draft: nothing unless a name is being typed
    /// after an `@`. A service's answer to an earlier query, still showing
    /// while this one is asked, has to match by title like everything else.
    public static func matches(for draft: String, in candidates: MentionCandidates,
                               limit: Int = limit) -> [Mention] {
        guard let query = SessionMentions.query(in: draft) else { return [] }
        let current = candidates.searchedFor == query
        let stale = current || query.isEmpty ? [] : candidates.searched
        return ranked(query: query,
                      lanes: candidates.lanes + stale,
                      searched: current ? candidates.searched : [],
                      resolved: candidates.resolved, limit: limit)
    }

    /// `lanes` are the sources, each already in the order a bare `@` should
    /// offer it, and first lane first on a tie.
    ///
    /// A bare `@` takes the lanes in turn. A typed query ranks everything by a
    /// title starting with it, then the fuzzy score, then by place in its own
    /// lane, so one lane's length does not push another's first entries down.
    ///
    /// `searched` lanes are taken as the service ordered them, never through
    /// the title match: `@ENG-412` finds an issue titled "Crash when the socket
    /// drops". They take turns with the ranked list, so the first of each
    /// shows whatever the rest match.
    ///
    /// `resolved` are ranked the same way among themselves and go after all of
    /// it; a bare `@` leaves them out.
    public static func ranked<M: Mentionable>(
        query: String,
        lanes: [[M]],
        searched: [[M]] = [],
        resolved: [M] = [],
        limit: Int = limit
    ) -> [M] {
        ranked(query: query, lanes: lanes, searched: searched, last: [], resolved: resolved, limit: limit)
    }


    /// `last` is a lane that goes after everything else and takes at most half
    /// the menu while anything else is left to show.
    private static func ranked<M: Mentionable>(
        query: String,
        lanes: [[M]],
        searched: [[M]],
        last: [M],
        resolved: [M],
        limit: Int
    ) -> [M] {
        let local = lanes + [last]
        let lastLane = local.count - 1
        let found = searched.enumerated().map { lane, items in items.map { ($0, lane: -1 - lane) } }
        if query.isEmpty {
            let own = lanes.enumerated().map { lane, items in items.map { ($0, lane: lane) } }
            let ordered = inTurn(own + found + [last.map { ($0, lane: lastLane) }])
            return filled(ordered, limit: limit, capped: lastLane, share: limit / 2)
        }
        let ranked = scoring(query, local).sorted(by: Scored.before).map { ($0.item, $0.lane) }
        let live = filled(inTurn([ranked] + found), limit: limit, capped: lastLane, share: limit / 2)
        let done = scoring(query, [resolved]).sorted(by: Scored.before).map(\.item)
        return live + done.prefix(limit - live.count)
    }

    private static func scoring<M: Mentionable>(_ query: String, _ lanes: [[M]]) -> [Scored<M>] {
        let lowered = query.lowercased()
        return lanes.enumerated().flatMap { lane, items in
            items.enumerated().compactMap { position, item -> Scored<M>? in
                guard let match = FuzzyMatch.match(query, in: item.title) else { return nil }
                return Scored(item: item, lane: lane, position: position, score: match.score,
                              leads: item.title.lowercased().hasPrefix(lowered))
            }
        }
    }

    /// The first of each, then the second of each, and so on.
    private static func inTurn<M>(_ queues: [[(M, lane: Int)]]) -> [(M, lane: Int)] {
        (0..<(queues.map(\.count).max() ?? 0)).flatMap { position in
            queues.compactMap { position < $0.count ? $0[position] : nil }
        }
    }

    private struct Scored<M> {
        let item: M
        let lane: Int
        let position: Int
        let score: Int
        let leads: Bool

        static func before(_ left: Scored, _ right: Scored) -> Bool {
            if left.leads != right.leads { return left.leads }
            if left.score != right.score { return left.score > right.score }
            if left.position != right.position { return left.position < right.position }
            return left.lane < right.lane
        }
    }

    /// The first `limit` in order, with the capped lane's overflow held back
    /// and used only if nothing else is left to fill the menu.
    private static func filled<M>(_ ordered: [(M, lane: Int)], limit: Int, capped: Int, share: Int) -> [M] {
        var picked: [(M, Int)] = []
        var held: [Int] = []
        var taken = 0
        for (index, entry) in ordered.enumerated() where picked.count < limit {
            if entry.lane == capped {
                guard taken < share else { held.append(index); continue }
                taken += 1
            }
            picked.append((entry.0, index))
        }
        let room = limit - picked.count
        picked += held.prefix(room).map { (ordered[$0].0, $0) }
        return picked.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
