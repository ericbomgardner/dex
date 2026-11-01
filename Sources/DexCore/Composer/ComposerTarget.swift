import Foundation

public enum ComposerTarget {

    /// The project the list is filtered to, if it is filtered to one. New
    /// sessions go there no matter what the composer last picked.
    public static func pinned(to selectedProject: String?) -> String? {
        guard let selectedProject, !selectedProject.isEmpty else { return nil }
        return selectedProject
    }

    public static func resolve(
        selectedProject: String?,
        lastUsed: String?,
        rows: [SessionRowModel],
        home: String = NSHomeDirectory(),
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String {
        picked(selectedProject: selectedProject, lastUsed: lastUsed, rows: rows,
               directoryExists: directoryExists) ?? home
    }

    /// The folder something pointed the composer at, as against the home directory
    /// it lands on with nothing to go on. Only the first is a folder anyone named.
    public static func picked(
        selectedProject: String?,
        lastUsed: String?,
        rows: [SessionRowModel],
        directoryExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        if let pinned = pinned(to: selectedProject) {
            return pinned
        }
        if let lastUsed, !lastUsed.isEmpty, directoryExists(lastUsed) {
            return lastUsed
        }
        return rows.max(by: { $0.session.startedAt < $1.session.startedAt })?.projectPath
    }

    public static func name(for path: String, in projects: [ProjectSummary]) -> String {
        if let match = projects.first(where: { $0.path == path }) {
            return match.name
        }
        let leaf = URL(fileURLWithPath: path).lastPathComponent
        return leaf.isEmpty ? path : leaf
    }
}
