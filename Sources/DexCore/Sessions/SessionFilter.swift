import Foundation

public struct SessionFilter: Sendable, Hashable {

    public var project: String?

    /// Only the sessions this background watcher started, by its name.
    public var watcher: String?

    public var resolutions: SessionResolutions

    public init(
        project: String? = nil,
        watcher: String? = nil,
        resolutions: SessionResolutions = SessionResolutions()
    ) {
        self.project = project
        self.watcher = watcher
        self.resolutions = resolutions
    }

    public struct Result: Sendable {
        public var visible: [SessionRowModel]

        public var blockedElsewhere: Int

        public init(visible: [SessionRowModel], blockedElsewhere: Int = 0) {
            self.visible = visible
            self.blockedElsewhere = blockedElsewhere
        }
    }

    public func apply(to rows: [SessionRowModel]) -> Result {

        var visible: [SessionRowModel] = []
        var blockedElsewhere = 0

        for row in rows {
            let outside = (project.map { row.projectPath != $0 } ?? false)
                || (watcher.map { row.origin?.watcher != $0 } ?? false)
            if outside {
                if resolutions.isWaitingOnYou(row) { blockedElsewhere += 1 }
            } else {
                visible.append(row)
            }
        }

        return Result(visible: visible, blockedElsewhere: blockedElsewhere)
    }
}
