import Foundation

/// Where the app writes what sibling agents read, such as the fleet file.
public enum SupportDirectory {

    public static func url(configDirectory: URL = ConfigDirectory.resolve()) -> URL {
        configDirectory.appendingPathComponent(BundleIdentity.supportFolder, isDirectory: true)
    }
}
