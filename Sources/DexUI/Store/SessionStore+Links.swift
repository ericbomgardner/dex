import DexCore
import AppKit
import Foundation

extension SessionStore {
    // Bringing a session on screen, from a notification or a fresh dispatch

    func focus(sessionID: String) {
        let row = snapshot.rows.first { $0.session.sessionId == sessionID }
        links.requestFocus(sessionID: sessionID)

        guard let row else {
            refresh()
            return
        }

        reveal(row)
        links.scroll(to: row)
    }

    /// A `dex://session/…` link. It waits a while for its row rather than
    /// failing on the first snapshot: the link may be what launched the app.
    func open(_ link: SessionLink) {
        guard takeBack(link) else { return }
        links.wait(for: link)
        showWindow()
        openPendingLink()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(LinkRouter.linkPatience))
            self?.openPendingLink()
        }
    }

    /// Opened in whichever app ran it, so the conversation carries on where it was.
    func open(_ hit: TranscriptHit) {
        closeOverlay()
        let link = SessionLink(sessionID: hit.sessionID, name: hit.title, cwd: hit.cwd)
        open(link)
    }

    /// A link to a session on this Mac that the list has let go of — the
    /// archive keeps a week — is listed again off its transcript.
    private func takeBack(_ link: SessionLink) -> Bool {
        guard
              !snapshot.rows.contains(where: { $0.session.sessionId == link.sessionID }),
              !hostedArchive.stored.values.contains(where: {
                  $0.sessionId == link.sessionID
              }),
              let facts = TranscriptSearch().facts(sessionID: link.sessionID)
        else { return true }

        guard FileManager.default.fileExists(atPath: facts.cwd) else {
            toasts.report(ActionOutcome(
                label: facts.title ?? link.name ?? "Open session",
                succeeded: false,
                message: "the folder it ran in, \(Format.tildePath(facts.cwd)), is gone"
            ))
            return false
        }
        var archive = hostedArchive
        archive.adopt(
            sessionId: link.sessionID, cwd: facts.cwd, name: facts.title,
            model: facts.model
        )
        hostedArchive = archive
        rebuildRows()
        return true
    }

    func openPendingLink() {
        switch links.pendingLink(in: snapshot.rows) {
        case .nothing, .stillWaiting:
            return
        case .gaveUp(let link):
            toasts.report(ActionOutcome(
                label: link.name ?? "Open session",
                succeeded: false,
                message: "Dex no longer lists this session — its transcript is \(link.sessionID).jsonl"
            ))
        case .found(let row):
            showWindow()
            show(row)
        }
    }

    func showWindow() {
        links.showWindow()
    }

    /// Brings a session up the way clicking its row does: past whatever the list
    /// is filtered to, scrolled to, and attached in the pane.
    func show(_ row: SessionRowModel, opening prompt: String? = nil) {
        reveal(row)
        links.scroll(to: row)
        openPane(on: row, opening: prompt)
    }

    func reveal(_ row: SessionRowModel) {
        if let project = selectedProject,
           row.projectPath != project {
            selectedProject = nil
        }
        if let watcherFilter, row.origin?.watcher != watcherFilter {
            self.watcherFilter = nil
        }
        if resolutions.isSettled(row) { showsSettled = true }
    }

    func showWatchers() {
        showWindow()
        showsWatchers = true
    }
}
