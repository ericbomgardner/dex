import Foundation

public enum ConfigDirectory {
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.userHome
    ) -> URL {
        if let override = environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return home.appendingPathComponent(".claude")
    }
}

extension FileManager {
    public var userHome: URL {
        homeDirectoryForCurrentUser
    }
}
