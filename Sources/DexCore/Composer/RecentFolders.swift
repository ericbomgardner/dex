import Foundation

/// Every folder the composer has been pointed at, by when it last was. The
/// picker's other source is the session list, and a session ages out of the
/// archive in a week, so a folder picked once and left alone used to fall out
/// of the picker with it.
public struct RecentFolders: Codable, Hashable, Sendable {

    /// Newest kept past this. Forty is more folders than the menu can usefully
    /// show, and the ones past it are by definition the least used.
    public static let capacity = 40

    public private(set) var lastUsed: [String: Date]

    public init(_ lastUsed: [String: Date] = [:]) {
        self.lastUsed = lastUsed
    }

    public var isEmpty: Bool { lastUsed.isEmpty }

    public var paths: [String] { Array(lastUsed.keys) }

    public func contains(_ path: String) -> Bool {
        lastUsed[path] != nil
    }

    public mutating func note(_ path: String, at now: Date = Date()) {
        guard !path.isEmpty else { return }
        lastUsed[path] = now
        guard lastUsed.count > Self.capacity else { return }
        let kept = lastUsed.sorted { $0.value > $1.value }.prefix(Self.capacity)
        lastUsed = Dictionary(uniqueKeysWithValues: Array(kept))
    }

    /// Forgets folders that are gone, on the same terms the archive forgets
    /// sessions in them. Asked where the archive is pruned rather than where the
    /// menu is drawn, so drawing the menu touches no disk.
    public mutating func prune(keeping stillThere: (String) -> Bool) {
        lastUsed = lastUsed.filter { stillThere($0.key) }
    }
}

/// What the composer's folder picker offers: every project with a session, and
/// every folder picked before, most recently used first.
public enum ComposerFolders {

    public static func list(
        rows: [SessionRowModel],
        recents: RecentFolders,
        resolutions: SessionResolutions = SessionResolutions(),
        counting isActive: (SessionRowModel) -> Bool = { _ in true }
    ) -> [ProjectSummary] {
        let summaries = ProjectIndex.summaries(
            for: rows, also: recents.paths, resolutions: resolutions, counting: isActive
        )

        var touched = recents.lastUsed
        for row in rows {
            let known = touched[row.projectPath]
            if known == nil || known! < row.lastUpdatedAt {
                touched[row.projectPath] = row.lastUpdatedAt
            }
        }

        return summaries.sorted { lhs, rhs in
            switch (touched[lhs.path], touched[rhs.path]) {
            case let (left?, right?) where left != right: return left > right
            case (nil, .some): return false
            case (.some, nil): return true
            default: return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
        }
    }
}
