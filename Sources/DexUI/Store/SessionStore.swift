import DexCore
import AppKit
import Foundation
import Observation
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "store")

@MainActor
@Observable
final class SessionStore {
    let flavor: AppFlavor

    private(set) var snapshot = Snapshot()

    var selectedProject: String? {
        didSet {
            Defaults.selectedProject = selectedProject
            detachHiddenSession()
        }
    }

    var showsSettled = false

    /// Half-answered questions, held here rather than by the card that draws
    /// them: the card is built again whenever the pane is pointed at another
    /// session, and an answer typed into it used to go with the old one. Not
    /// written to disk — an ask dies with the host that raised it.
    var askDrafts = AskDrafts()

    /// The sessions currently let onto the pointer or keyboard.
    let takeovers: ScreenTakeovers

    let preferences = Preferences()

    let composer = ComposerModel()

    let modelNames = ModelNames()

    private let sleepHold: SleepHold

    var resolutions: SessionResolutions {
        didSet { Defaults.resolutions = resolutions }
    }

    /// What the app knows about sessions the host is not running, which is all
    /// that is left of one once its host has gone.
    var hostedArchive: HostedArchive {
        didSet { Defaults.hostedArchive = hostedArchive }
    }

    let presenter = NotificationPresenter()
    let notifications: NotificationCoordinator
    let rebuilder = Rebuilder()
    let toasts = OutcomeToasts()
    let claude = ClaudeLookup()
    private let staleHost: StaleHostReplacer
    private let merges: WorktreeMerges
    let retirer: WorktreeRetirer
    private let fleet: FleetPublisher

    let watchers = BackgroundWatchers()

    /// Only the sessions this background watcher started. Not remembered across
    /// launches: a list that opens filtered with nothing on screen to say why
    /// reads as sessions gone missing.
    var watcherFilter: String?

    /// The window's watcher list, so a notification can open it.
    var showsWatchers = false

    let pane = SessionPane()

    /// Sessions asked for and not yet seen, and what each was launched as.
    let dispatches: DispatchController

    /// Focus, scroll and link requests, which the window answers.
    let links = LinkRouter()

    /// This Mac's host, spawned beside the app and kept under its own name: it
    /// is the only one that can be replaced.
    let host: HostSessions

    /// Linear issues and Notion pages for `@`.
    let linkedWork = LinkedWork.stored()

    /// Every ask a host is holding.
    private var pendingAsks: [HostAsk] {
        return host.asks.pending
    }

    private func isHeld(_ key: String) -> Bool {
        return host.sessions[key] != nil
    }

    /// What each local row's title and second line are read from.
    private let readings: TranscriptReadings

    /// What each session was started with, standing in as its second line for
    /// the second before its transcript exists to be read. Kept by host key,
    /// which a session has from the moment it is dispatched — its transcript id,
    /// which everything else about a row is filed under, it does not.
    private var openings: [String: SessionDigest] = [:]

    private let worktrees = WorktreeIndex()
    let directories: any DirectoryProbe = FileSystemDirectoryProbe()
    /// The same object for the same files, every time asked. It goes into the
    /// pane's environment, and a new one on every redraw handed every row of
    /// every transcript a new environment to adopt.
    @ObservationIgnored let localSource = LocalTranscriptSource()

    /// This app's own build commit, off its Info.plist — written there by
    /// make-app.sh. **Not `rebuilder.runningBuild`**, which resolves only when
    /// the bundle sits inside a checkout's `.build`, so it is nil for the very
    /// installed copy this whole path exists for. Nil from a `swift run` dev
    /// build, which carries no stamp and so is never judged stale.
    let appBuildCommit: String? = AppCheckout.buildCommit { Bundle.main.object(forInfoDictionaryKey: $0) }

    private var timerTask: Task<Void, Never>?
    private var quietTask: Task<Void, Never>?
    private var wakeObserver: (any NSObjectProtocol)?
    private var activationObserver: (any NSObjectProtocol)?

    init(flavor: AppFlavor) {
        self.flavor = flavor
        self.host = HostSessions(identity: flavor.host)
        self.staleHost = StaleHostReplacer(host: host, rebuilder: rebuilder, appBuildCommit: appBuildCommit)
        self.readings = TranscriptReadings(transcripts: TranscriptLocator())
        self.takeovers = ScreenTakeovers(
            host: host, presenter: presenter, preferences: preferences, transcripts: readings.transcripts
        )
        self.dispatches = DispatchController(pane: pane, toasts: toasts)
        self.notifications = NotificationCoordinator(
            presenter: presenter, preferences: preferences, watchers: watchers
        )
        let probe = GitCommandProbe()
        self.merges = WorktreeMerges(git: probe, runningBuild: rebuilder.runningBuild)
        self.retirer = WorktreeRetirer(git: probe, runningBuild: rebuilder.runningBuild, toasts: toasts)
        self.fleet = FleetPublisher(
            host: host
        )
        self.selectedProject = Defaults.selectedProject
        self.sleepHold = SleepHold(allowed: Defaults.keepsAwake)
        self.resolutions = Defaults.resolutions
        self.hostedArchive = Defaults.hostedArchive

        connectParts()
    }

    /// What each part the store owns asks back of it. Weak throughout: the
    /// parts live as long as the store, and their tasks outlive neither.
    private func connectParts() {
        preferences.onNotificationsOn = { [weak self] in self?.presenter.requestAuthorization() }
        preferences.onKeepsAwake = { [weak self] keeps in self?.sleepHold.allowed = keeps }
        readings.wanted = { [weak self] in self?.host.ordered.compactMap(\.sessionId) ?? [] }
        readings.onMoved = { [weak self] in self?.rebuildRows(refreshingDigests: false) }
        readings.onLook = { [weak self] in self?.rebuildRows() }
        dispatches.onBound = { [weak self] rowID, opening in self?.openings[rowID] = opening }
        notifications.reading = { [weak self] in
            guard let self else {
                return .init(rows: [], resolutions: SessionResolutions(), hasNeverLoaded: true)
            }
            return .init(
                rows: self.snapshot.rows,
                resolutions: self.resolutions,
                hasNeverLoaded: self.snapshot.hasNeverLoaded
            )
        }
        notifications.onScreen = { [weak self] in self?.rowsOnScreen() ?? [] }
        notifications.standing = { [weak self] in self.map { Set($0.takeovers.keys) } ?? [] }
        takeovers.row = { [weak self] key in self?.snapshot.rows.first { $0.rowID == key } }
        takeovers.onEnded = { [weak self] in self?.withdrawOvertakenNotifications() }
        retirer.standing = { [weak self] in self.map { ($0.snapshot.rows, $0.resolutions) } }
        fleet.rename = { [weak self] id, title in
            guard let self else { return }
            self.rename(sessionId: id, to: title, on: self.host, quietly: true)
        }
    }

    // Lifecycle

    func start() {
        installLinkedLookups()
        rebuilder.onOutcome = { [weak self] outcome in self?.toasts.report(outcome) }
        // Pushed, not polled: the host says when something moved, and the list
        // rebuilds without waiting for the next reconcile.
        host.onChange = { [weak self] in self?.hostChanged() }
        host.onWork = { [weak self] in self?.staleHost.hostChanged() }
        host.onRefusal = { [weak self] subject, what, why in
            self?.toasts.hostRefused(subject, what, because: why)
        }
        host.onTakeoverAllowed = { [weak self] ask in self?.takeovers.began(ask) }
        host.onEvent = { [weak self] event in
            switch event {
            case .sessionInit(let start):
                self?.resumeArrived(start.key)
            case .launch(let request): self?.launchRequested(request)
            case .sessionExit(let key, let reason):
                self?.dispatches.resumeFailed(key, because: reason)
                self?.dispatches.dispatchFailed(key, because: reason)
                self?.takeovers.ended(key)
            case .ask(let ask) where ask.kind == .takeover:
                self?.takeovers.decide(ask)
            case .sessionStatus(let key, let state):
                self?.takeovers.statusChanged(key, to: state)
            // Kept across launches, because the CLI answers for its styles only
            // while a session is running and the picker is one you open before
            // starting anything.
            case .outputStyles(let styles) where !styles.isEmpty:
                self?.preferences.knownOutputStyles = styles
            case .welcome(let welcome):
                if let styles = welcome.outputStyles, !styles.isEmpty {
                    self?.preferences.knownOutputStyles = styles
                }
                self?.staleHost.replaceIfStale()
            default: break
            }
        }
        pane.context = self
        pane.hostSend = { [weak self] key, text in self?.sendToHosted(key: key, text: text) }

        host.start()
        watchers.onChange = { [weak self] in self?.watchersChanged() }
        watchers.start()

        observeWake()
        observeActivation()
        scheduleLoop()
        startWatchingTranscripts()
        readModelNames()
    }

    func prepareNotifications() {
        presenter.onOpenSession = { [weak self] sessionID in
            self?.focus(sessionID: sessionID)
        }
        presenter.onOpenWatchers = { [weak self] in self?.showWatchers() }
        presenter.prepare()
        if preferences.postsNotifications { presenter.requestAuthorization() }
    }

    func stop() {
        timerTask?.cancel()
        timerTask = nil
        links.stop()
        quietTask?.cancel()
        quietTask = nil
        readings.stop()
        watchers.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
            self.activationObserver = nil
        }
    }

    private func observeWake() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    private func observeActivation() {
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.withdrawOvertakenNotifications()
            }
        }
    }

    // Reading the session list

    /// The reconcile still earns its keep with no poll behind it: merge statuses
    /// move when git moves outside the app, and quiet-dimming and ages need a
    /// periodic redraw.
    private func scheduleLoop() {
        timerTask?.cancel()
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                try? await Task.sleep(for: .seconds(PollPolicy.reconcileInterval))
            }
        }
    }

    func refresh() {
        rebuildRows()
        pruneResolutions()
        startMergePass()
        Task { await dropSelectionIfProjectDeleted() }
    }

    /// The host said something moved, so the list rebuilds without waiting for
    /// the next reconcile.
    func hostChanged() {
        // Every ask the host is holding, not just the attached session's: a
        // question is answered from wherever the pane happens to be, and
        // pruning to one session's would throw away another's answers.
        askDrafts.keep(AskPages.read(pendingAsks))
        // A host that goes away takes its sessions with it and says nothing
        // per session, so a grant is dropped here on the host's own list: a
        // bar over a session no host is holding could never come down.
        for key in takeovers.keys where !isHeld(key) {
            takeovers.ended(key)
        }
        rebuildRows()
        staleHost.hostChanged()
    }

    var isWaitingToReplaceHost: Bool { staleHost.isWaiting }

    func rebuildRows(refreshingDigests: Bool = true) {
        let previous = snapshot.rows

        let worktrees = self.worktrees

        // The last reading of each live session, used twice: for the row the
        // host is running, and for what the archive keeps of it. Only live
        // sessions are read at all — nothing writes to a stopped one's
        // transcript. The file itself is read off the main thread, below: a
        // busy session moves its file on every host event, and a rebuild that
        // went to disk for each one held the window for the read.
        var readings: [String: SessionDigest] = [:]
        for summary in host.ordered {
            // No session id yet means the SDK hasn't named the file, and the
            // opening below is the whole of what the row has to say.
            guard let sessionID = summary.sessionId else { continue }
            readings[summary.key] = self.readings.latest(sessionID: sessionID) ?? SessionDigest()
        }
        if refreshingDigests { self.readings.refreshDigests() }

        // What was typed stands under the reading rather than over it, so the
        // row says something from its first frame and the file takes the line
        // over the moment it has one — which is the same sentence, read back.
        let seeded = readings.merging(openings) { read, opening in read.merged(over: opening) }

        let hosted = host.rows { worktrees.origin(of: $0) } digest: {
            (seeded[$0.key] ?? SessionDigest())
        }
        let heard = Set(readings.filter { $0.value.lastMessage != nil }.keys)
        let live = Set(host.sessions.keys)

        rememberHostedSessions(seeded)
        pruneRecentFolders()

        let archived = hostedArchive.rows(besides: live) { entry in
            return worktrees.origin(of: entry.cwd)
        }

        let origins = watchers.originsByKey
        snapshot.rows = (hosted + archived)
            .map { row in
                // A resume is sent without an origin, and the archived row that
                // kept it is hidden while the key is live.
                guard row.origin == nil,
                    let origin = hostedArchive.entry(key: row.rowID)?.origin ?? origins[row.rowID]
                else { return row }
                return row.withOrigin(origin)
            }
        sleepHold.working = KeepAwake.shouldHold(rows: snapshot.rows, live: live)
        // The file has said something of its own, so what was typed has been
        // read back and the stand-in is done. Until then it stays for as long
        // as anything holds the key: the host answers `start` before it
        // announces the session, and a rebuild landing in that beat used to
        // find the key on no host and drop the line for good.
        let dispatched = Set(dispatches.boundRowIDs)
        openings = openings.filter { key, _ in
            !heard.contains(key) && (live.contains(key) || dispatched.contains(key))
        }

        // The open pane may have attached before the SDK opened the session's
        // transcript; the id it was missing arrives on a later event, here.
        if let current = pane.attachment, current.sessionID == nil,
           let sessionID = snapshot.rows
               .first(where: { $0.rowID == current.hostKey })?.session.sessionId {
            pane.adopt(sessionID: sessionID)
        }

        // "Loaded" is the host having answered, one way or the other — rows off
        // the socket, or the reason it is unusable. Before either, the list is
        // still starting; without the second half, an app whose host never
        // came up has never "loaded" and stale notifications are never
        // withdrawn.
        if snapshot.fetchedAt == nil, host.isRunning || host.unavailable != nil {
            snapshot.fetchedAt = Date()
        }

        applyKnownMergeStatuses()

        // A row arrives here rather than through a poll, so this is where a
        // dispatch waiting on one gets to claim it.
        resolvePendingDispatches()
        openPendingLink()

        self.readings.watch(snapshot.rows
        )
        notifications.announce(from: previous, to: snapshot.rows)
        withdrawOvertakenNotifications()
        publishFleet()
        let awaited = hosted
        self.readings.awaitTranscripts(awaited, given: readings)
    }

    /// Written down while the host still has them, since afterwards there is
    /// nothing left to read: a hosted session is the host's memory plus the file
    /// it writes, and the file says nothing about which key it ran under.
    private func rememberHostedSessions(_ readings: [String: SessionDigest]) {
        var archive = hostedArchive
        for summary in host.ordered {
            archive.record(
                summary,
                digest: readings[summary.key] ?? SessionDigest(),
                lastActivityAt: host.lastActivityAt(key: summary.key)
            )
        }
        archive.prune(probe: directories)
        guard archive != hostedArchive else { return }
        hostedArchive = archive
    }

    private func pruneRecentFolders() {
        composer.pruneRecentFolders(keeping: directories.stillThere)
    }

    private func dropSelectionIfProjectDeleted() async {
        guard let selected = selectedProject else { return }
        let probe = directories

        let exists = await Task.detached(priority: .utility) {
            probe.stillThere(selected)
        }.value

        if !exists, selectedProject == selected {
            logger.notice("project filter \(selected, privacy: .public) no longer exists — showing all")
            selectedProject = nil
        }
    }

    // Merge state, resolved off the read so the rows show first

    private func applyKnownMergeStatuses() {
        guard !merges.isEmpty else { return }
        for index in snapshot.rows.indices {
            let status = merges.status(of: snapshot.rows[index].rowID)
            guard status != snapshot.rows[index].mergeStatus else { continue }
            snapshot.rows[index] = snapshot.rows[index].withMergeStatus(status)
        }
    }

    private func startMergePass() {
        let rows = snapshot.rows
        merges.resolve(rows) { [weak self] in
            self?.applyKnownMergeStatuses()
            self?.publishFleet()
        }
    }

    // The fleet, written where the agents in it can read it

    /// Local rows only. The fleet file is read by agents on this Mac, and
    /// `SessionRegistry` is this machine's own.
    private func publishFleet() {
        fleet.publish(snapshot.rows
        )
    }

    // Writes, which refresh ahead of the reconcile

    private func startWatchingTranscripts() {
        readings.startWatching(snapshot.rows) { [weak self] rowID, at, url in
            self?.noteActivity(rowID: rowID, at: at, url: url)
        }
    }

    /// Every write, not only the ones that move the host's record: a message you
    /// send lands here a beat after you send it, and this is the read that gets
    /// the row saying so while the session is still thinking about it.
    private func noteActivity(rowID: String, at date: Date, url: URL) {
        guard let index = snapshot.rows.firstIndex(where: { $0.rowID == rowID }) else { return }

        // The same rule the read joins the file on, asked again here: the watch
        // is set up per read and a write is answered 400ms later, so a session
        // the list has since given up on can still have one in flight — and a
        // turn owed by a session that has stopped is one nobody is working on.
        let live = snapshot.rows[index].session.isLive

        // The row's second line is the newest thing in the file that just
        // changed, and nothing else re-reads it between turns: the host emits on
        // state changes, and a turn runs from its first tool call to its last
        // without changing state. Left to the reconcile it would trail the work
        // by half a minute. Not while it is asking, though — that line is the
        // ask, and it belongs to the socket rather than to the file.
        let sessionID = snapshot.rows[index].isAsking
            ? nil
            : snapshot.rows[index].session.sessionId

        Task {
            let read = await readings.readWrite(at: url, live: live, sessionID: sessionID)

            self.applyActivity(
                rowID: rowID,
                at: date,
                owesTurn: read.owed,
                title: read.digest?.title,
                hostedSummary: read.digest?.lastMessage,
                context: read.digest?.context,
                mcpCalls: read.digest?.mcpCalls
            )
        }
    }

    func applyActivity(
        rowID: String,
        at date: Date,
        owesTurn owed: Bool,
        title: String? = nil,
        hostedSummary: String? = nil,
        context: SessionContext? = nil,
        mcpCalls: [String: McpCallOutcome]? = nil
    ) {
        guard let index = snapshot.rows.firstIndex(where: { $0.rowID == rowID }) else { return }

        // Each write answers on a task of its own, and nothing makes them finish
        // in the order they started: two in flight over a busy session can land
        // back to front, and the older one would walk the row's line back to
        // work that has already finished. Newest wins, or nothing does.
        guard date >= snapshot.rows[index].lastActivityAt ?? .distantPast else { return }

        snapshot.rows[index] = snapshot.rows[index].refreshed(
            activityAt: date,
            owesTurn: owed,
            // The name the CLI wrote into the file about a second in. The row is
            // built from the host's word and rebuilt only when the host has one,
            // so this is what gets the name onto a row that is busy working
            // rather than a minute later.
            title: title,
            // Asked again on the way back in: the read went off the main actor,
            // and a session that put a question up while it was out would have
            // its ask written over by the work that prompted it.
            hostedSummary: snapshot.rows[index].isAsking ? nil : hostedSummary,
            context: context,
            mcpCalls: mcpCalls
        )
        scheduleQuietCheck()
    }

    /// Nothing reads `activityCheckedAt`. Writing it is the point: a row that has
    /// gone quiet is only quiet by the clock, and touching the snapshot is what
    /// makes the list redraw and dim it.
    private func scheduleQuietCheck() {
        quietTask?.cancel()
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(ActivitySignal.quietAfter))
            guard !Task.isCancelled else { return }
            self?.snapshot.activityCheckedAt = Date()
        }
    }

    // What is drawn over the window

    /// One slot, so the palette and the composer can't both be up.
    enum Overlay: Hashable {
        case quickSwitch(QuickSwitchScope)
        case composer
        case search
    }

    private(set) var overlay: Overlay?

    func openQuickSwitch(_ scope: QuickSwitchScope) {
        overlay = .quickSwitch(scope)
    }

    func openSearch() {
        overlay = .search
    }

    func openComposer() {
        overlay = .composer
        pruneRecentFolders()
        readModelNames()
    }

    func closeOverlay() {
        overlay = nil
    }
}
