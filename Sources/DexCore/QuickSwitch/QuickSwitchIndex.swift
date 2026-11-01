import Foundation

public enum QuickSwitchScope: String, Sendable, Hashable {

    case everything

    case projectsOnly
}

public enum QuickSwitchItem: Sendable, Hashable, Identifiable {
    case allProjects
    case project(ProjectSummary)
    case session(SessionRowModel)

    public var id: String {
        switch self {
        case .allProjects: "all-projects"
        case .project(let summary): "project:\(summary.path)"
        case .session(let row): "session:\(row.rowID)"
        }
    }

    public var name: String {
        switch self {
        case .allProjects: QuickSwitchIndex.allProjectsName
        case .project(let summary): summary.name
        case .session(let row): row.session.displayName
        }
    }
}

public struct QuickSwitchResult: Sendable, Hashable, Identifiable {
    public let item: QuickSwitchItem

    /// Indices of the characters in `name` the query matched, for emphasis.
    public let highlights: [Int]

    public var id: String { item.id }
    public var name: String { item.name }

    public init(item: QuickSwitchItem, highlights: [Int] = []) {
        self.item = item
        self.highlights = highlights
    }
}

public struct QuickSwitchResults: Sendable, Hashable {
    public let projects: [QuickSwitchResult]
    public let sessions: [QuickSwitchResult]

    /// Both groups in the order they are drawn, which is what the arrow keys walk.
    public let ordered: [QuickSwitchResult]

    public var isEmpty: Bool { ordered.isEmpty }

    public init(projects: [QuickSwitchResult] = [], sessions: [QuickSwitchResult] = []) {
        self.projects = projects
        self.sessions = sessions
        self.ordered = projects + sessions
    }
}

public enum QuickSwitchIndex {

    public static let allProjectsName = "All Projects"

    /// Matches names only — a query never matches a folder path, so typing the
    /// name of a parent directory doesn't light up everything beneath it.
    public static func results(
        query: String,
        scope: QuickSwitchScope = .everything,
        projects: [ProjectSummary],
        sessions: [SessionRowModel],
        isFiltered: Bool
    ) -> QuickSwitchResults {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)

        var found = rank(
            byRecency(projects, sessions: sessions).map(QuickSwitchItem.project),
            query: query
        )
        if isFiltered, let clear = matched(.allProjects, query: query) {
            found.append(clear)
        }

        guard scope == .everything else {
            return QuickSwitchResults(projects: found)
        }
        return QuickSwitchResults(
            projects: found,
            sessions: rank(sessions.map(QuickSwitchItem.session), query: query)
        )
    }

    /// Waiting on you first, then whichever project was touched most recently.
    /// Sessions arrive already ordered that way, so they are left alone.
    private static func byRecency(
        _ projects: [ProjectSummary],
        sessions: [SessionRowModel]
    ) -> [ProjectSummary] {
        var touched: [String: Date] = [:]
        for row in sessions {
            let known = touched[row.projectPath]
            if known == nil || known! < row.lastUpdatedAt {
                touched[row.projectPath] = row.lastUpdatedAt
            }
        }

        return projects.sorted { lhs, rhs in
            if (lhs.blocked > 0) != (rhs.blocked > 0) { return lhs.blocked > 0 }

            switch (touched[lhs.path], touched[rhs.path]) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }

    private static func rank(_ items: [QuickSwitchItem], query: String) -> [QuickSwitchResult] {
        guard !query.isEmpty else { return items.map { QuickSwitchResult(item: $0) } }

        let scored = items.enumerated().compactMap { order, item in
            FuzzyMatch.match(query, in: item.name).map { (item, $0, order) }
        }

        return scored.sorted { lhs, rhs in
            if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
            if lhs.0.name.count != rhs.0.name.count { return lhs.0.name.count < rhs.0.name.count }
            return lhs.2 < rhs.2
        }
        .map { QuickSwitchResult(item: $0.0, highlights: $0.1.matched) }
    }

    private static func matched(_ item: QuickSwitchItem, query: String) -> QuickSwitchResult? {
        guard !query.isEmpty else { return QuickSwitchResult(item: item) }
        return FuzzyMatch.match(query, in: item.name)
            .map { QuickSwitchResult(item: item, highlights: $0.matched) }
    }
}
