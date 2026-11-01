import DexCore
import AppKit
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "folders")

/// The apps a folder can be handed to. One that isn't installed is left out of
/// the menu rather than offered and then quietly doing nothing.
enum FolderApp: CaseIterable {
    case terminal
    case gitx
    case finder

    var title: String {
        switch self {
        case .terminal: "Terminal"
        case .gitx: "GitX"
        case .finder: "Finder"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .terminal: "com.apple.Terminal"
        case .gitx: "net.phere.GitX"
        case .finder: "com.apple.finder"
        }
    }

    var applicationURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    static var installed: [FolderApp] {
        allCases.filter { $0.applicationURL != nil }
    }

    func open(_ path: String) {
        guard let application = applicationURL else { return }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true

        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path, isDirectory: true)],
            withApplicationAt: application,
            configuration: configuration
        ) { _, error in
            guard let error else { return }
            logger.error("could not open \(path, privacy: .public) in \(title, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
