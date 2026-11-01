import Foundation

public enum BranchMergeState: Sendable, Hashable {

    case merged

    case outstanding(commits: Int)

    case branchGone

    public var hasOutstandingCommits: Bool {
        if case .outstanding = self { return true }
        return false
    }
}

/// Only ever answered for the one checkout the running bundle came out of.
public enum BuildInclusion: Sendable, Hashable {

    case inBuild

    case awaitingRestart
}

public struct WorktreeMergeStatus: Sendable, Hashable {

    public let base: String

    public let merge: BranchMergeState

    public let uncommittedFiles: Int?

    public let build: BuildInclusion?

    public init(
        base: String,
        merge: BranchMergeState,
        uncommittedFiles: Int? = nil,
        build: BuildInclusion? = nil
    ) {
        self.base = base
        self.merge = merge
        self.uncommittedFiles = uncommittedFiles
        self.build = build
    }

    public var needsAttention: Bool {
        merge.hasOutstandingCommits || (uncommittedFiles ?? 0) > 0
    }

    public var awaitsRestart: Bool { build == .awaitingRestart }

    /// Landed and quiet is the ordinary end of a session and draws nothing.
    public var isNotable: Bool { needsAttention || awaitsRestart }

    public enum Tone: Sendable, Hashable {

        case landed

        case attention

        case awaitingRestart

        case indeterminate
    }

    public var tone: Tone {
        if needsAttention { return .attention }
        if awaitsRestart { return .awaitingRestart }
        switch merge {
        case .merged: return .landed
        case .branchGone: return .indeterminate

        case .outstanding: return .attention
        }
    }

    public var label: String {
        guard awaitsRestart else { return mergeLabel }
        guard let dirty = uncommittedFiles, dirty > 0 else { return "not in this build" }
        return "not in this build · \(dirty) uncommitted"
    }

    /// What the fleet file says, where "this build" would mean nothing.
    public var mergeLabel: String {
        switch merge {
        case .merged:
            guard let dirty = uncommittedFiles, dirty > 0 else { return "in \(base)" }
            return "\(dirty) uncommitted"
        case .outstanding(let commits):
            let plural = commits == 1 ? "commit" : "commits"
            guard let dirty = uncommittedFiles, dirty > 0 else {
                return "\(commits) \(plural) not in \(base)"
            }
            return "\(commits) \(plural) not in \(base) · \(dirty) uncommitted"
        case .branchGone:
            return "branch gone"
        }
    }

    public var help: String {
        switch merge {
        case .merged:
            var text = "every commit on this branch is in \(base)"
            if let dirty = uncommittedFiles, dirty > 0 {
                text += ", but \(dirty) file\(dirty == 1 ? "" : "s") in the worktree "
                    + "\(dirty == 1 ? "is" : "are") uncommitted"
            }
            if awaitsRestart {
                text += ". This app was built from a commit that came before it — "
                    + "rebuild and restart to run it"
            }
            return text
        case .outstanding(let commits):
            return "\(commits) commit\(commits == 1 ? "" : "s") on this branch "
                + "\(commits == 1 ? "has" : "have") no equivalent in \(base). "
                + "A squash-merge looks the same as unmerged from here — the squashed "
                + "commit has a different patch id, and nothing in the repository ties them together."
        case .branchGone:
            return "the branch this session recorded no longer exists in the repository. "
                + "Usually that means merged and cleaned up, but a discarded branch "
                + "looks identical, so this doesn't claim either."
        }
    }
}

public protocol GitProbe: Sendable {

    func branches(inRepository repository: String) -> [String]?

    func branches(inRepository repository: String, mergedInto base: String) -> [String]?

    func outstandingCommitCount(base: String, branch: String, inRepository repository: String) -> Int?

    func symbolicRefTarget(_ ref: String, inRepository repository: String) -> String?

    func headBranch(inRepository repository: String) -> String?

    func uncommittedFileCount(inWorktree path: String) -> Int?

    /// What says two paths are the same repository, however far apart they sit.
    func commonDirectory(inRepository repository: String) -> String?

    /// Whether a branch ever moved after it was created, or nil if nothing recorded it.
    func branchMoved(sinceCreationOf branch: String, inRepository repository: String) -> Bool?
}

public enum MergeState {
    public static let conventionalBaseBranches = ["main", "master"]

    public static func baseBranch(
        originHead: String?,
        branches: [String],
        checkedOutBranch: @autoclosure () -> String?
    ) -> String? {
        let existing = Set(branches)

        if let originHead {
            let name = originHead.hasPrefix("origin/")
                ? String(originHead.dropFirst("origin/".count))
                : originHead
            if existing.contains(name) { return name }
        }

        if let conventional = conventionalBaseBranches.first(where: existing.contains) {
            return conventional
        }

        if let head = checkedOutBranch(), existing.contains(head) { return head }

        return nil
    }

    public static func commonDirectory(inOutput output: String, repository: String) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let path = trimmed.hasPrefix("/")
            ? trimmed
            : (repository as NSString).appendingPathComponent(trimmed)
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    public static func moved(inReflogOutput output: String) -> Bool? {
        let entries = output
            .split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
        return entries == 0 ? nil : entries > 1
    }

    public static func outstandingCommits(inCherryOutput output: String) -> Int {
        output
            .split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("+") }
            .count
    }

    public static func mergeState(
        branch: String,
        existingBranches: Set<String>,
        mergedBranches: Set<String>,
        outstandingCommits: () -> Int?
    ) -> BranchMergeState? {
        guard existingBranches.contains(branch) else { return .branchGone }
        if mergedBranches.contains(branch) { return .merged }

        guard let count = outstandingCommits() else { return nil }
        return count == 0 ? .merged : .outstanding(commits: count)
    }
}

public enum MergeStateResolver {

    public static func isEligible(_ row: SessionRowModel) -> Bool {
        row.worktreeBranch != nil && row.session.hasFinishedWorking
    }

    public static func resolve(
        rows: [SessionRowModel],
        probe: some GitProbe,
        runningBuild: RunningBuild? = nil
    ) -> [String: WorktreeMergeStatus] {
        let eligible = rows.filter(isEligible)
        guard !eligible.isEmpty else { return [:] }

        let target = runningBuild.flatMap { build in
            probe.commonDirectory(inRepository: build.checkoutRoot).map {
                BuildTarget(commit: build.commit, commonDirectory: $0)
            }
        }

        let repositories = Array(Set(eligible.map(\.projectPath))).sorted()
        let factsList = inParallel(repositories) {
            RepositoryFacts.read(repository: $0, probe: probe, build: target)
        }
        let facts = Dictionary(uniqueKeysWithValues: zip(repositories, factsList))

        // Every worktree of a repository shares its refs, so this is read once.
        func isBuiltFrom(_ repositoryFacts: RepositoryFacts?) -> Bool {
            guard let target, let directory = repositoryFacts?.commonDirectory else { return false }
            return directory == target.commonDirectory
        }
        let inBuild: Set<String>? = target.flatMap { target in
            repositories
                .first { isBuiltFrom(facts[$0] ?? nil) }
                .flatMap { probe.branches(inRepository: $0, mergedInto: target.commit) }
                .map(Set.init)
        }

        var cherryKeys: [BranchKey] = []
        var worktrees: [String] = []
        for row in eligible {
            guard let branch = row.worktreeBranch,
                  let repositoryFacts = facts[row.projectPath] ?? nil
            else { continue }

            let key = BranchKey(repository: row.projectPath, branch: branch)
            if repositoryFacts.branches.contains(branch),
               !repositoryFacts.merged.contains(branch),
               !cherryKeys.contains(key) {
                cherryKeys.append(key)
            }
            if let worktree = row.worktreePath, !worktrees.contains(worktree) {
                worktrees.append(worktree)
            }
        }

        let cherryCounts = Dictionary(uniqueKeysWithValues: zip(
            cherryKeys,
            inParallel(cherryKeys) { key in
                facts[key.repository].flatMap { $0 }.flatMap {
                    probe.outstandingCommitCount(
                        base: $0.base, branch: key.branch, inRepository: key.repository
                    )
                }
            }
        ))
        let dirtyCounts = Dictionary(uniqueKeysWithValues: zip(
            worktrees,
            inParallel(worktrees) { probe.uncommittedFileCount(inWorktree: $0) }
        ))

        var merges: [BranchKey: BranchMergeState] = [:]
        for row in eligible {
            guard let branch = row.worktreeBranch,
                  let repositoryFacts = facts[row.projectPath] ?? nil
            else { continue }

            let key = BranchKey(repository: row.projectPath, branch: branch)
            guard merges[key] == nil,
                  let merge = MergeState.mergeState(
                      branch: branch,
                      existingBranches: repositoryFacts.branches,
                      mergedBranches: repositoryFacts.merged,
                      outstandingCommits: { cherryCounts[key] ?? nil }
                  )
            else { continue }
            merges[key] = merge
        }

        // Everything ancestry would report as missing from the build, before saying so.
        var candidates: [BranchKey] = []
        for row in eligible {
            guard let branch = row.worktreeBranch,
                  let repositoryFacts = facts[row.projectPath] ?? nil,
                  isBuiltFrom(repositoryFacts),
                  let inBuild
            else { continue }

            let key = BranchKey(repository: row.projectPath, branch: branch)
            if merges[key] == .merged, !inBuild.contains(branch), !candidates.contains(key) {
                candidates.append(key)
            }
        }

        let evidence = Dictionary(uniqueKeysWithValues: zip(
            candidates,
            inParallel(candidates) { key in
                let landedInBase = (facts[key.repository] ?? nil)?.merged.contains(key.branch) == true

                // A rebase-landed branch is no ancestor of the build either, and never will be.
                return BuildEvidence(
                    moved: probe.branchMoved(sinceCreationOf: key.branch, inRepository: key.repository),
                    outstanding: landedInBase ? nil : target.flatMap {
                        probe.outstandingCommitCount(
                            base: $0.commit, branch: key.branch, inRepository: key.repository
                        )
                    }
                )
            }
        ))

        var byRow: [String: WorktreeMergeStatus] = [:]
        for row in eligible {
            guard let branch = row.worktreeBranch,
                  let repositoryFacts = facts[row.projectPath] ?? nil
            else { continue }

            let key = BranchKey(repository: row.projectPath, branch: branch)
            guard let merge = merges[key] else { continue }

            byRow[row.rowID] = WorktreeMergeStatus(
                base: repositoryFacts.base,
                merge: merge,
                uncommittedFiles: row.worktreePath.flatMap { dirtyCounts[$0] ?? nil },
                build: inclusion(
                    merge: merge,
                    key: key,
                    landedInBase: repositoryFacts.merged.contains(branch),
                    inBuild: isBuiltFrom(repositoryFacts) ? inBuild : nil,
                    evidence: evidence[key]
                )
            )
        }

        return byRow
    }

    private static func inclusion(
        merge: BranchMergeState,
        key: BranchKey,
        landedInBase: Bool,
        inBuild: Set<String>?,
        evidence: BuildEvidence?
    ) -> BuildInclusion? {
        guard merge == .merged, let inBuild else { return nil }
        if inBuild.contains(key.branch) { return .inBuild }

        // A branch that never moved sits on someone else's commit, carrying no work.
        if evidence?.moved == false { return .inBuild }

        // Ancestry is what said this landed, so ancestry settles the build too.
        if landedInBase { return .awaitingRestart }

        guard let outstanding = evidence?.outstanding else { return nil }
        return outstanding == 0 ? .inBuild : .awaitingRestart
    }

    private static func inParallel<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        _ body: @Sendable (Input) -> Output
    ) -> [Output] {
        guard inputs.count > 1 else { return inputs.map(body) }
        let answers = Answers<Output>(count: inputs.count)
        DispatchQueue.concurrentPerform(iterations: inputs.count) { index in
            answers.set(body(inputs[index]), at: index)
        }

        return answers.ordered
    }

    private final class Answers<Output>: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Output?]

        init(count: Int) {
            values = Array(repeating: nil, count: count)
        }

        func set(_ value: Output, at index: Int) {
            lock.lock()
            values[index] = value
            lock.unlock()
        }

        var ordered: [Output] {
            lock.lock()
            defer { lock.unlock() }
            return values.map { $0! }
        }
    }

    private struct BranchKey: Hashable {
        let repository: String
        let branch: String
    }

    private struct BuildTarget {
        let commit: String
        let commonDirectory: String
    }

    private struct BuildEvidence {
        let moved: Bool?
        let outstanding: Int?
    }

    private struct RepositoryFacts {
        let base: String
        let branches: Set<String>
        let merged: Set<String>

        /// Read only when there is a build to compare it against.
        let commonDirectory: String?

        static func read(
            repository: String,
            probe: some GitProbe,
            build: BuildTarget?
        ) -> RepositoryFacts? {
            guard let branches = probe.branches(inRepository: repository) else { return nil }
            let base = MergeState.baseBranch(
                originHead: probe.symbolicRefTarget("refs/remotes/origin/HEAD", inRepository: repository),
                branches: branches,
                checkedOutBranch: probe.headBranch(inRepository: repository)
            )
            guard let base,
                  let merged = probe.branches(inRepository: repository, mergedInto: base)
            else { return nil }

            return RepositoryFacts(
                base: base,
                branches: Set(branches),
                merged: Set(merged),
                commonDirectory: build == nil ? nil : probe.commonDirectory(inRepository: repository)
            )
        }
    }
}
