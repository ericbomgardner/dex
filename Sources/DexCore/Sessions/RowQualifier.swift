import Foundation

public struct RowProjectLabels: Sendable, Hashable {
    private let names: [String: String]

    public init(rows: [SessionRowModel], selectedProject: String?) {
        guard selectedProject == nil else {
            self.names = [:]
            return
        }
        self.names = ProjectIndex.displayNames(for: rows.map(\.projectPath))
    }

    public func label(for row: SessionRowModel) -> String? {
        names[row.projectPath]
    }

    public func path(for row: SessionRowModel) -> String {
        Format.tildePath(row.projectPath)
    }
}
