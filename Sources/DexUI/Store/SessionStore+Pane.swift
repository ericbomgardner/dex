import DexCore
import Foundation

/// The attached pane: what a pane asks of the host about its session lives
/// on `SessionPane`, one per window, and reaches the store only through this.
extension SessionStore: PaneContext {
    func row(forKey key: String) -> SessionRowModel? {
        snapshot.rows.first { $0.rowID == key }
    }

    func host(holding key: String?) -> HostSessions {
        host
    }

    func isArchived(key: String) -> Bool {
        hostedArchive.entry(key: key) != nil
    }

    func launchedModel(forKey key: String) -> SessionModel? {
        dispatches.launchedModels[key]
    }

    func effortChanged(_ effort: EffortLevel, forKey key: String) {
    }
}

extension SessionStore {
    /// Letting go is safe: the pane only ever ran a viewer, never the agent.
    /// An app with no project filter lets its pane go only of a session
    /// that was resolved.
    func detachHiddenSession() {
        guard let key = pane.attachment?.hostKey,
              let row = snapshot.rows.first(where: { $0.rowID == key }),
              AttachedSession.isOutOfView(
                  row, project:
                      selectedProject,
                  resolutions: resolutions
              )
        else { return }
        pane.close()
    }

    func openPane(on row: SessionRowModel, opening prompt: String? = nil) {
        pane.open(
            PaneAttachment(
                hostKey: row.session.hostKey,
                // Nil for a folder that is gone: everything this is handed to
                // reads the folder off this disk.
                workingDirectory:
                    directories.stillThere(row.projectPath)
                    ? row.projectPath
                    : nil,
                sessionID: row.session.sessionId,
                openingPrompt: prompt
            )
        )
    }
}
