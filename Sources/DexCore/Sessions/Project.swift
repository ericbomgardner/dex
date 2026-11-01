import Foundation

public struct Project: Sendable, Hashable, Identifiable {

    public let path: String

    public let name: String

    public var id: String { path }

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }
}

public struct ProjectSummary: Sendable, Hashable, Identifiable {
    public let project: Project

    public let total: Int

    public let active: Int

    public let blocked: Int
    public let live: Int

    public var id: String { project.path }
    public var name: String { project.name }
    public var path: String { project.path }

    public init(project: Project, total: Int, active: Int, blocked: Int, live: Int) {
        self.project = project
        self.total = total
        self.active = active
        self.blocked = blocked
        self.live = live
    }
}

public enum ProjectIndex {

    public static func summaries(
        for rows: [SessionRowModel],
        also paths: [String] = [],
        resolutions: SessionResolutions = SessionResolutions(),
        counting isActive: (SessionRowModel) -> Bool = { _ in true }
    ) -> [ProjectSummary] {
        var grouped = Dictionary(grouping: rows, by: \.projectPath)
        for path in paths where grouped[path] == nil {
            grouped[path] = []
        }
        let names = displayNames(for: Array(grouped.keys))

        return grouped.map { path, rows in
            ProjectSummary(
                project: Project(path: path, name: names[path] ?? path),
                total: rows.count,
                active: rows.count(where: isActive),
                blocked: rows.count(where: resolutions.isWaitingOnYou),
                live: rows.count(where: { $0.session.isLive })
            )
        }
        .sorted { lhs, rhs in
            switch lhs.name.localizedStandardCompare(rhs.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.path < rhs.path
            }
        }
    }

    static func displayNames(for paths: [String]) -> [String: String] {
        let unique = Set(paths)
        var depth = Dictionary(uniqueKeysWithValues: unique.map { ($0, 1) })

        let deepest = unique.map { components($0).count }.max() ?? 1
        for _ in 0..<max(1, deepest) {
            var extended = false
            let byRendering = Dictionary(grouping: unique) { render($0, depth: depth[$0] ?? 1) }
            for (_, colliding) in byRendering where colliding.count > 1 {
                for path in colliding where (depth[path] ?? 1) < components(path).count {
                    depth[path] = (depth[path] ?? 1) + 1
                    extended = true
                }
            }
            if !extended { break }
        }

        return Dictionary(uniqueKeysWithValues: unique.map {
            ($0, render($0, depth: depth[$0] ?? 1))
        })
    }

    private static func components(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private static func render(_ path: String, depth: Int) -> String {
        let parts = components(path)
        guard !parts.isEmpty else { return path }
        let take = min(max(depth, 1), parts.count)

        guard take < parts.count else { return Format.tildePath(path) }
        return parts.suffix(take).joined(separator: "/")
    }
}
