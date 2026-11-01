import Foundation

public struct TranscriptLocator: Sendable {
    public let configDirectory: URL

    public init(configDirectory: URL = ConfigDirectory.resolve()) {
        self.configDirectory = configDirectory
    }

    private var projectsDirectory: URL {
        configDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    public func locate(sessionID: String?) -> URL? {
        guard let sessionID, !sessionID.isEmpty else { return nil }
        return search(sessionID: sessionID)
    }

    private func search(sessionID: String) -> URL? {
        let manager = FileManager.default
        guard let projects = try? manager.contentsOfDirectory(
            at: projectsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        // Projects are folders named for a directory, so a session that changes
        // its own — into a worktree, say — is filed under a second one. The live
        // transcript is whichever was written to last.
        let filename = "\(sessionID).jsonl"
        return projects
            .map { $0.appendingPathComponent(filename) }
            .filter { manager.fileExists(atPath: $0.path) }
            .max { (lastWrite(at: $0) ?? .distantPast) < (lastWrite(at: $1) ?? .distantPast) }
    }

    public func lastWrite(at url: URL) -> Date? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.modificationDate] as? Date
    }
}
