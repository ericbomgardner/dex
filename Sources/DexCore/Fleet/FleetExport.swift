import Foundation

/// Publishes the fleet snapshot where agents can read it.
public final class FleetExport: @unchecked Sendable {

    public let file: URL

    private let lock = NSLock()
    private var lastPublished: [FleetSession]?

    public init(directory: URL, name: String = "fleet.json") {
        self.file = directory.appendingPathComponent(name)
    }

    public static func encode(_ snapshot: FleetSnapshot) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(snapshot)
    }

    /// Returns whether it wrote. The poll ticks whether or not anything moved,
    /// so an unchanged fleet must not rewrite the file — otherwise a session
    /// watching it is woken every 30s by its own timestamp.
    @discardableResult
    public func publish(_ snapshot: FleetSnapshot) throws -> Bool {
        lock.lock()
        let unchanged = lastPublished == snapshot.sessions
        lock.unlock()
        if unchanged, FileManager.default.fileExists(atPath: file.path) { return false }

        let data = try Self.encode(snapshot)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: file, options: .atomic)

        lock.lock()
        lastPublished = snapshot.sessions
        lock.unlock()
        return true
    }
}
