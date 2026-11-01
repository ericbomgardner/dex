import DexCore
import AppKit
import Foundation

extension SessionStore {
    // What the list shows

    var orderedRows: [SessionRowModel] {
        SessionOrdering.sorted(snapshot.rows, resolutions: resolutions)
    }

    /// The rows under the project filter: what the list shows, and what the
    /// sweep and the on-screen count go by.
    var filtered: SessionFilter.Result {
        SessionFilter(project: selectedProject, watcher: watcherFilter, resolutions: resolutions)
            .apply(to: orderedRows)
    }

    var sections: SessionSections {
        resolutions.split(filtered.visible)
    }

    var activeItems: [SessionListItem] {
        SessionOrdering.merged(sections.active, starting: dispatches.pending, resolutions: resolutions)
    }

    var waitingCount: Int {
        SessionOrdering.blockedCount(snapshot.rows, resolutions: resolutions)
    }

    var projects: [ProjectSummary] {
        let marks = resolutions
        return ProjectIndex.summaries(for: snapshot.rows, resolutions: marks) {
            SessionSections.counts($0, resolutions: marks)
        }
    }

    var projectLabels: RowProjectLabels {
        RowProjectLabels(rows: snapshot.rows, selectedProject: selectedProject)
    }

    /// Whether a folder is one on this Mac and actually there: a local row's
    /// folder can have been deleted under it.
    func isLocalFolder(_ path: String) -> Bool {
        return directories.stillThere(path)
    }

    var selectedProjectName: String? {
        guard let selectedProject else { return nil }
        return ComposerTarget.name(for: selectedProject, in: projects)
    }

    // Resolving

    var resolvableNow: [SessionRowModel] {
        resolutions.resolvable(in: filtered.visible)
    }

    func resolve(_ row: SessionRowModel) {
        resolutions.resolve(row)
        detachHiddenSession()
        withdrawOvertakenNotifications()
        retirer.retireWorktrees(of: [row], among: snapshot.rows)
    }

    /// The sweep retires the swept rows' checkouts the way the tick does —
    /// without this the two verbs mean different things and a menu-swept tree
    /// stays.
    func resolveAllVisible() {
        let swept = resolvableNow
        guard !swept.isEmpty else { return }

        resolutions.resolveAll(in: filtered.visible)
        detachHiddenSession()
        withdrawOvertakenNotifications()
        retirer.retireWorktrees(of: swept, among: snapshot.rows)
    }

    func unresolve(_ row: SessionRowModel) {
        resolutions.clear(row)
    }

    func canRename(_ row: SessionRowModel) -> Bool {
        guard row.session.sessionId != nil else { return false }
        return host.canRename
    }

    func rename(_ row: SessionRowModel, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = row.session.sessionId, !title.isEmpty else { return }
        rename(sessionId: id, to: title, on: host, quietly: false)
    }

    func rename(sessionId id: String, to title: String, on renamer: HostSessions, quietly: Bool) {
        renamer.rename(sessionId: id, title: title, quietly: quietly) { [weak self] in
            guard let self else { return }
            var archive = hostedArchive
            archive.rename(sessionId: id, to: title)
            guard archive != hostedArchive else { return }
            hostedArchive = archive
            rebuildRows()
        }
    }

    func pruneResolutions() {
        let live = Set(snapshot.rows.map(\.rowID))
        var pruned = resolutions
        pruned.prune(keeping: live)
        guard pruned != resolutions else { return }
        resolutions = pruned
    }

    /// Every project, and every session the list would show without a filter —
    /// so resolved ones stay out of the way here as well.
    func quickSwitchResults(query: String, scope: QuickSwitchScope) -> QuickSwitchResults {
        QuickSwitchIndex.results(
            query: query,
            scope: scope,
            projects:
                projects,
            sessions: resolutions.split(orderedRows).active,
            isFiltered: selectedProject != nil
        )
    }

    func activate(_ item: QuickSwitchItem) {
        closeOverlay()

        switch item {
        case .allProjects:
            selectedProject = nil
        case .project(let summary):
            selectedProject = summary.path
        case .session(let row):
            show(row)
        }
    }

    /// Every MCP server this Mac's running sessions name, and how each is doing.
    var mcpServers: [McpServerSummary] {
        McpServerSummary.of(Array(host.sessions.values))
    }

    /// Running sessions that have said anything about their servers yet.
    var mcpReportingSessions: Int {
        host.sessions.values.filter { $0.mcpServers != nil }.count
    }

    // Notifications

    func withdrawOvertakenNotifications() {
        notifications.withdrawOvertaken()
    }

    // Background watchers

    func watchersChanged() {
        rebuildRows(refreshingDigests: false)
        notifications.announceWatchers()
    }

    func rowsOnScreen() -> Set<String> {
        guard NSApp.isActive else { return [] }
        return Set(filtered.visible.map(\.rowID))
    }
}
