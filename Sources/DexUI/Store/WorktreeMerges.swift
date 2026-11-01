import DexCore
import Foundation

/// Merge state, resolved off the read so the rows show first. One pass at a
/// time, run off the main actor: every probe in the resolver shells out to git.
@MainActor
final class WorktreeMerges {
    private let git: any GitProbe
    private let runningBuild: RunningBuild?
    private var statuses: [String: WorktreeMergeStatus] = [:]
    private var pass: Task<Void, Never>?

    init(git: any GitProbe, runningBuild: RunningBuild?) {
        self.git = git
        self.runningBuild = runningBuild
    }

    var isEmpty: Bool { statuses.isEmpty }

    func status(of rowID: String) -> WorktreeMergeStatus? { statuses[rowID] }

    /// `changed` runs only when the pass found something the last one didn't.
    func resolve(_ rows: [SessionRowModel], changed: @escaping @MainActor () -> Void) {
        guard pass == nil else { return }
        let probe = git
        let build = runningBuild
        pass = Task { [weak self] in
            let statuses = await Task.detached(priority: .utility) {
                MergeStateResolver.resolve(rows: rows, probe: probe, runningBuild: build)
            }.value
            guard let self else { return }
            self.pass = nil
            guard statuses != self.statuses else { return }
            self.statuses = statuses
            changed()
        }
    }
}
