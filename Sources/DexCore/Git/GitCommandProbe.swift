import Foundation

public struct GitCommandProbe: GitProbe, WorktreeRemover {

    public var executable: String

    public init(executable: String = "git") {
        self.executable = executable
    }

    public func branches(inRepository repository: String) -> [String]? {
        refNames(["for-each-ref", "--format=%(refname:short)", "refs/heads/"], in: repository)
    }

    public func branches(inRepository repository: String, mergedInto base: String) -> [String]? {
        refNames(
            ["for-each-ref", "--merged", base, "--format=%(refname:short)", "refs/heads/"],
            in: repository
        )
    }

    public func outstandingCommitCount(
        base: String,
        branch: String,
        inRepository repository: String
    ) -> Int? {
        guard let output = run(["cherry", base, branch], in: repository) else { return nil }
        return MergeState.outstandingCommits(inCherryOutput: output)
    }

    public func symbolicRefTarget(_ ref: String, inRepository repository: String) -> String? {
        run(["symbolic-ref", "--short", ref], in: repository)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    public func headBranch(inRepository repository: String) -> String? {
        symbolicRefTarget("HEAD", inRepository: repository)
    }

    public func commonDirectory(inRepository repository: String) -> String? {
        guard let output = run(["rev-parse", "--git-common-dir"], in: repository) else { return nil }
        return MergeState.commonDirectory(inOutput: output, repository: repository)
    }

    public func branchMoved(sinceCreationOf branch: String, inRepository repository: String) -> Bool? {
        guard let output = run(["reflog", "show", branch], in: repository) else { return nil }
        return MergeState.moved(inReflogOutput: output)
    }

    public func uncommittedFileCount(inWorktree path: String) -> Int? {
        guard let output = run(["--no-optional-locks", "status", "--porcelain"], in: path)
        else { return nil }
        return output.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }

    /// No `--force`, so git's own reading of the tree gets the last word.
    public func removeWorktree(at path: String, inRepository repository: String) -> Bool {
        run(["worktree", "remove", path], in: repository) != nil
    }

    private func refNames(_ arguments: [String], in repository: String) -> [String]? {
        guard let output = run(arguments, in: repository) else { return nil }
        return output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func run(_ arguments: [String], in directory: String) -> String? {

        let result = try? Shell.run([executable, "-C", directory] + arguments)
        guard let result, result.exitCode == 0 else { return nil }
        return result.stdoutText
    }
}
