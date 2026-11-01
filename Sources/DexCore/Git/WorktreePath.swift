import Foundation

/// A worktree path as one spelling: git lays one out and a row carries one,
/// and compared unstandardized a trailing slash quietly reads as a different
/// tree.
public enum WorktreePath {

    public static func key(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "" }
        return (trimmed as NSString).standardizingPath
    }

    /// Whether `directory` is the worktree or somewhere inside it.
    public static func contains(_ root: String, _ directory: String) -> Bool {
        let root = key(root), directory = key(directory)
        guard !root.isEmpty else { return false }
        // On a boundary, or `landing-gate` would claim `landing-gate-two`.
        return directory == root || directory.hasPrefix(root + "/")
    }
}
