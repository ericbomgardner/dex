import Foundation

/// A checkout a resolved row is finished with, named the way git needs it back.
public struct RetiredWorktree: Sendable, Hashable {

    public let path: String

    public let branch: String

    public let repository: String

    public init(path: String, branch: String, repository: String) {
        self.path = path
        self.branch = branch
        self.repository = repository
    }
}

/// Removing a checkout — the one thing the app does to a repository that it
/// cannot take back. Kept off `GitProbe` so that reading a repository and
/// destroying part of one are not the same capability.
public protocol WorktreeRemover: Sendable {

    /// Removes the checkout and leaves the branch. Never forced: a tree git
    /// calls dirty stays, whatever this side concluded about it.
    func removeWorktree(at path: String, inRepository repository: String) -> Bool
}

/// Whether the worktree a row worked in can go, now that the row is resolved.
///
/// Resolving is cheap and reversible — it takes a row off the list and a second
/// click puts it back — so this does deliberately less than a merge script would: the
/// checkout goes and the **branch stays**. Every commit on it is in the base
/// branch by the time this answers yes, so the branch carries no work; what it
/// buys is that the tree comes back with one `git worktree add` rather than not
/// at all. Deleting the branch is left to whatever merged it.
public enum WorktreeRetirement {

    /// The half that costs nothing: whether this row names a checkout worth
    /// asking git about at all.
    ///
    /// `hasFinishedWorking` rather than the resolve's own gate, which is wider —
    /// `canResolve` takes a blocked row and an idle-but-working one, and both
    /// are sessions you mean to come back to. Other rows are read because a
    /// worktree can outlast the session that made it: one resumed under a new
    /// key is a second row on the same path, and the row being resolved says
    /// nothing about what that one is still doing.
    public static func nominee(
        _ row: SessionRowModel,
        among rows: [SessionRowModel],
        runningBuild: RunningBuild? = nil
    ) -> RetiredWorktree? {
        guard let path = row.worktreePath, let branch = row.worktreeBranch else { return nil }
        guard isDone(row) else { return nil }

        let key = WorktreePath.key(path)
        let shared = rows.contains {
            $0.rowID != row.rowID
                && $0.worktreePath.map(WorktreePath.key) == key
                && !isDone($0)
        }
        guard !shared else { return nil }

        // The checkout this app was built from is where its own rebuild runs.
        if let root = runningBuild?.checkoutRoot, WorktreePath.contains(key, root) { return nil }

        return RetiredWorktree(path: key, branch: branch, repository: row.projectPath)
    }

    /// The half that asks git, on the same terms the row badge was drawn on.
    ///
    /// Read again rather than taken from `mergeStatus`: the status is resolved
    /// off a background pass, and a commit made since would leave it saying
    /// merged about work that isn't. `.branchGone` is not treated as merged —
    /// a branch that has been cleaned up and one that was discarded look
    /// identical from here, and only one of them is safe.
    public static func isFinished(_ tree: RetiredWorktree, probe: some GitProbe) -> Bool {
        guard probe.uncommittedFileCount(inWorktree: tree.path) == 0 else { return false }
        guard let branches = probe.branches(inRepository: tree.repository),
              let base = MergeState.baseBranch(
                  originHead: probe.symbolicRefTarget(
                      "refs/remotes/origin/HEAD", inRepository: tree.repository
                  ),
                  branches: branches,
                  checkedOutBranch: probe.headBranch(inRepository: tree.repository)
              ),
              base != tree.branch,
              let merged = probe.branches(inRepository: tree.repository, mergedInto: base)
        else { return false }

        return MergeState.mergeState(
            branch: tree.branch,
            existingBranches: Set(branches),
            mergedBranches: Set(merged),
            outstandingCommits: {
                probe.outstandingCommitCount(
                    base: base, branch: tree.branch, inRepository: tree.repository
                )
            }
        ) == .merged
    }

    /// Whether the nomination still stands, asked on the last hop before the
    /// tree goes.
    ///
    /// `isFinished` is a subprocess apiece and the row can come back while they
    /// run: the same click unresolves it, or the session is handed another turn
    /// and hasn't touched a file yet, so git still reads clean and merged.
    /// `isSettled` answers both — it goes false on its own once a settled row
    /// says something new. A row that has left the list entirely is no
    /// contradiction; nothing is left to be working in the tree.
    public static func stillNominated(
        _ tree: RetiredWorktree,
        rowID: String,
        among rows: [SessionRowModel],
        resolutions: SessionResolutions,
        runningBuild: RunningBuild? = nil
    ) -> Bool {
        guard let row = rows.first(where: { $0.rowID == rowID }) else { return true }
        guard resolutions.isSettled(row) else { return false }
        return nominee(row, among: rows, runningBuild: runningBuild) == tree
    }

    /// Both halves and the removal, for calling off the main thread. The app
    /// splits these so it can ask `stillNominated` in between; this is the
    /// whole of it for a caller with nothing to re-check.
    public static func retire(
        _ tree: RetiredWorktree,
        probe: some GitProbe & WorktreeRemover
    ) -> Bool {
        guard isFinished(tree, probe: probe) else { return false }
        return probe.removeWorktree(at: tree.path, inRepository: tree.repository)
    }

    private static func isDone(_ row: SessionRowModel) -> Bool {
        row.session.hasFinishedWorking && !row.session.isLive
    }
}
