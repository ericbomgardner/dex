import DexCore
import Foundation
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "fleet")

/// The fleet, written where the agents in it can read it, and the names the
/// registry asks for given to the sessions that have none.
@MainActor
final class FleetPublisher {
    private let host: HostSessions
    private let fleet = FleetExport(directory: SupportDirectory.url())

    /// Once per session: a rename that failed is not retried on every rebuild.
    private var namesGiven: Set<String> = []

    /// How a name is given, which the store owns: the archive keeps it too.
    var rename: ((_ sessionId: String, _ title: String) -> Void)?

    init(
        host: HostSessions
    ) {
        self.host = host
    }

    /// Written off the main actor, along with the registry read that gives
    /// each row its address.
    func publish(_ rows: [SessionRowModel]) {
        let published = FleetSnapshot(rows: rows, updatedAt: Date())
        // Not an archived row: its session id may be alive in a Terminal resume, where a rename only appends.
        let hosted = Set(host.ordered.compactMap(\.sessionId))
        let fleet = self.fleet
        let registry = SessionRegistry.directory()
        Task.detached(priority: .utility) { [weak self] in
            let entries = SessionRegistry.entries(in: registry)
            do {
                try fleet.publish(published.addressed(by: entries))
            } catch {
                logger.error("fleet export failed: \(String(describing: error), privacy: .public)")
            }
            let renames = SessionNaming.renames(rows, registry: entries).filter { hosted.contains($0.sessionId) }
            guard !renames.isEmpty else { return }
            await self?.giveNames(renames)
        }
    }

    private func giveNames(_ renames: [SessionNaming.Rename]) {
        guard host.canRename else { return }
        for rename in renames where namesGiven.insert(rename.sessionId).inserted {
            self.rename?(rename.sessionId, rename.title)
        }
    }
}
