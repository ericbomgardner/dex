import Foundation

public struct WorktreeOrigin: Sendable, Hashable {

    public let path: String

    public let branch: String?

    public init(path: String, branch: String? = nil) {
        self.path = path
        self.branch = branch
    }
}

public enum WorktreeLink {

    static func gitdirPointer(inLinkFile contents: String, relativeTo worktree: String) -> String? {
        let line = contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first?
            .trimmingCharacters(in: .whitespaces)
        guard let line, line.hasPrefix("gitdir:") else { return nil }

        let target = String(line.dropFirst("gitdir:".count)).trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return absolute(target, relativeTo: worktree)
    }

    static func commonDirectory(fromCommondirFile contents: String, relativeTo gitdir: String) -> String? {
        let target = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return nil }
        return absolute(target, relativeTo: gitdir)
    }

    static func repository(forCommonDirectory commonDirectory: String) -> String? {
        let url = URL(fileURLWithPath: commonDirectory).standardizedFileURL
        guard url.lastPathComponent == ".git" else { return nil }
        let repository = url.deletingLastPathComponent().standardizedFileURL.path
        return repository.isEmpty ? nil : repository
    }

    static func branch(fromHEAD contents: String) -> String? {
        let line = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("ref:") else { return nil }

        let ref = String(line.dropFirst("ref:".count)).trimmingCharacters(in: .whitespaces)
        let branch = ref.hasPrefix("refs/heads/")
            ? String(ref.dropFirst("refs/heads/".count))
            : ref
        return branch.isEmpty ? nil : branch
    }

    private static func absolute(_ path: String, relativeTo base: String) -> String {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path).standardizedFileURL.path
        }
        return URL(fileURLWithPath: path, relativeTo: URL(fileURLWithPath: base, isDirectory: true))
            .standardizedFileURL
            .path
    }
}

public final class WorktreeIndex: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: WorktreeOrigin?] = [:]

    public init() {}

    public func origin(of directory: String) -> WorktreeOrigin? {
        lock.lock()
        if let cached = cache[directory] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.resolve(directory)

        lock.lock()
        cache[directory] = resolved
        lock.unlock()
        return resolved
    }

    public static func resolve(_ directory: String) -> WorktreeOrigin? {
        let linkFile = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(".git")
            .standardizedFileURL

        guard let link = text(at: linkFile.path),
              let gitdir = WorktreeLink.gitdirPointer(inLinkFile: link, relativeTo: directory)
        else { return nil }

        guard let backReference = text(at: gitdir + "/gitdir"),
              URL(fileURLWithPath: backReference.trimmingCharacters(in: .whitespacesAndNewlines))
                  .standardizedFileURL.path == linkFile.path
        else { return nil }

        guard let commondir = text(at: gitdir + "/commondir"),
              let common = WorktreeLink.commonDirectory(fromCommondirFile: commondir, relativeTo: gitdir),
              let repository = WorktreeLink.repository(forCommonDirectory: common)
        else { return nil }

        return WorktreeOrigin(
            path: repository,
            branch: text(at: gitdir + "/HEAD").flatMap(WorktreeLink.branch(fromHEAD:))
        )
    }

    private static func text(at path: String) -> String? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              !isDirectory.boolValue
        else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }
}
