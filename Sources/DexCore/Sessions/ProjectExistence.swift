import Foundation

/// What the OS will say about a folder. macOS answers for a folder it is holding
/// back the same way it answers for one that was deleted, so the two are worth
/// telling apart: a project you have not granted the app is still a project.
public enum DirectorySighting: Sendable, Equatable {
    case directory
    case missing

    /// Something is there or nothing is; macOS won't say which until the folder
    /// it sits in has been granted.
    case withheld
}

public protocol DirectoryProbe: Sendable {
    func sighting(at path: String) -> DirectorySighting
}

extension DirectoryProbe {

    /// Whether to go on treating the folder as somewhere a session can live. One
    /// macOS won't talk about counts, because hiding a session that is still
    /// running is worse than listing one whose folder has gone.
    public func stillThere(_ path: String) -> Bool {
        sighting(at: path) != .missing
    }
}

public struct FileSystemDirectoryProbe: DirectoryProbe {
    public init() {}

    public func sighting(at path: String) -> DirectorySighting {
        var info = stat()
        guard stat(path, &info) == 0 else {
            return errno == ENOENT || errno == ENOTDIR ? .missing : .withheld
        }
        return (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) ? .directory : .missing
    }
}
