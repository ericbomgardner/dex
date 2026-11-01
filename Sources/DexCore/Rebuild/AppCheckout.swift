import Foundation

public protocol FileProbe: Sendable {
    func isFile(_ path: String) -> Bool
}

public struct FileSystemFileProbe: FileProbe {
    public init() {}

    public func isFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        return exists && !isDirectory.boolValue
    }
}

public struct AppCheckout: Sendable, Hashable {

    public let root: String

    public let bundlePath: String

    /// Whether this build came out of a linked worktree rather than the checkout
    /// the everyday copy is built in.
    public let isWorktree: Bool

    public init(root: String, bundlePath: String, isWorktree: Bool = false) {
        self.root = root
        self.bundlePath = bundlePath
        self.isWorktree = isWorktree
    }

    public var scriptPath: String { Layout.script(in: root) }

    public var name: String { (root as NSString).lastPathComponent }

    /// Which app this build is, by its bundle's name.
    public var bundleName: String { (bundlePath as NSString).lastPathComponent }

    public enum Layout {
        public static let buildDirectory = ".build"
        public static let bundleName = BundleIdentity.codeBundle
        public static let manifest = "Package.swift"
        public static let scriptPath = "Scripts/make-app.sh"

        /// A linked worktree keeps a `.git` *file* pointing at the real one, so
        /// which kind of checkout this is can be read off disk without git.
        public static let gitLink = ".git"

        /// Written into Info.plist by the build script, which nothing checks.
        public static let buildCommitKey = "DexBuildCommit"

        /// Read in this order. A key the build script no longer writes stays
        /// here until no installed bundle can still carry it.
        public static let buildCommitKeys = [
            buildCommitKey,
        ]

        static func script(in root: String) -> String {
            (root as NSString).appendingPathComponent(scriptPath)
        }

        static func manifest(in root: String) -> String {
            (root as NSString).appendingPathComponent(manifest)
        }

        static func gitLink(in root: String) -> String {
            (root as NSString).appendingPathComponent(gitLink)
        }
    }

    public static func resolve(bundlePath: String, files: FileProbe = FileSystemFileProbe()) -> AppCheckout? {
        let bundle = (bundlePath as NSString).standardizingPath
        let name = (bundle as NSString).lastPathComponent
        guard name == Layout.bundleName
        else { return nil }

        let buildDirectory = (bundle as NSString).deletingLastPathComponent
        guard (buildDirectory as NSString).lastPathComponent == Layout.buildDirectory else { return nil }

        let root = (buildDirectory as NSString).deletingLastPathComponent
        guard !root.isEmpty, root != "/" else { return nil }

        guard files.isFile(Layout.manifest(in: root)),
              files.isFile(Layout.script(in: root))
        else { return nil }

        return AppCheckout(
            root: root,
            bundlePath: bundle,
            isWorktree: files.isFile(Layout.gitLink(in: root))
        )
    }

    public func runningBuild(infoValue: Any?) -> RunningBuild? {
        Self.commit(fromInfoValue: infoValue).map {
            RunningBuild(commit: $0, checkoutRoot: root)
        }
    }

    /// The bundle's build commit, under whichever key it was stamped with.
    public static func buildCommit(info: (String) -> Any?) -> String? {
        for key in Layout.buildCommitKeys {
            if let commit = commit(fromInfoValue: info(key)) { return commit }
        }
        return nil
    }

    public static func commit(fromInfoValue value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (7...40).contains(trimmed.count), trimmed.allSatisfy(\.isHexDigit) else { return nil }
        return trimmed
    }
}

public struct RunningBuild: Sendable, Hashable {

    public let commit: String

    public let checkoutRoot: String

    public init(commit: String, checkoutRoot: String) {
        self.commit = commit
        self.checkoutRoot = checkoutRoot
    }
}
