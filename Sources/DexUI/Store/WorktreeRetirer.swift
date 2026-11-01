import DexCore
import Foundation

/// Removes the checkout a resolved row worked in, once its branch is merged
/// and nothing else is still working there.
@MainActor
final class WorktreeRetirer {
    /// The list as it stands now, asked again after each check: a row can
    /// start working in a tree while the check is out. Nil once the store is gone.
    typealias Standing = () -> (rows: [SessionRowModel], resolutions: SessionResolutions)?

    private let git: any GitProbe & WorktreeRemover
    private let runningBuild: RunningBuild?
    private let toasts: OutcomeToasts
    var standing: Standing = { nil }

    init(git: any GitProbe & WorktreeRemover, runningBuild: RunningBuild?, toasts: OutcomeToasts) {
        self.git = git
        self.runningBuild = runningBuild
        self.toasts = toasts
    }

    /// Resolving a finished row is also the end of the checkout it worked in.
    /// Nothing is reported when the trees stay: most resolved rows never had a
    /// worktree, and a toast for each of those is noise where the answer is
    /// simply "there was nothing to remove".
    ///
    /// One pass over the rows, one report at the end. A sweep is the case that
    /// makes both matter: `report` holds a single slot, so a toast apiece would
    /// leave you told about the last checkout removed and none of the others,
    /// and two finished rows on one path are both nominees — `nominee` only
    /// refuses a path another row is still *working* in — so the trees are
    /// deduped and removed in turn rather than raced against each other.
    func retireWorktrees(of rows: [SessionRowModel], among all: [SessionRowModel]) {
        var nominated: [(tree: RetiredWorktree, rowID: String)] = []
        var seen: Set<String> = []
        for row in rows {
            guard let tree = WorktreeRetirement.nominee(
                row, among: all, runningBuild: runningBuild
            ), seen.insert(tree.path).inserted else { continue }
            nominated.append((tree, row.rowID))
        }
        guard !nominated.isEmpty else { return }

        Task { [weak self] in
            var retired: [RetiredWorktree] = []
            for candidate in nominated {
                guard let self else { return }
                if await self.retire(candidate.tree, rowID: candidate.rowID) {
                    retired.append(candidate.tree)
                }
            }
            guard let self, let outcome = Self.retirementOutcome(retired) else { return }
            self.toasts.report(outcome)
        }
    }

    private func retire(_ tree: RetiredWorktree, rowID: String) async -> Bool {
        let probe = git
        let finished = await Task.detached(priority: .utility) {
            WorktreeRetirement.isFinished(tree, probe: probe)
        }.value
        guard finished, let now = standing(), WorktreeRetirement.stillNominated(
            tree,
            rowID: rowID,
            among: now.rows,
            resolutions: now.resolutions,
            runningBuild: runningBuild
        ) else { return false }

        return await Task.detached(priority: .utility) {
            probe.removeWorktree(at: tree.path, inRepository: tree.repository)
        }.value
    }

    private static func retirementOutcome(_ retired: [RetiredWorktree]) -> ActionOutcome? {
        guard let first = retired.first else { return nil }

        let message = retired.count == 1
            ? "\(Format.shortPath(first.path)) — \(first.branch) is merged, "
                + "and the branch is still there"
            : "\(retired.count) checkouts — every branch is merged, "
                + "and all of them are still there"

        return ActionOutcome(
            label: retired.count == 1 ? "Worktree removed" : "Worktrees removed",
            succeeded: true,
            message: message,
            successMessageRestatesLabel: false
        )
    }
}
