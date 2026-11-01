import DexCore
import Foundation
import Observation
import os

private let logger = Logger(subsystem: BundleIdentity.code, category: "host")

/// The sessions this app is hosting, as opposed to the ones it found.
///
/// Everything here is pushed rather than polled: the host says when a session's
/// state changes and when one is holding out a question, so nothing in this
/// type has an interval. What it does not carry is transcript content — a
/// hosted session writes the same `~/.claude/projects` file every other session
/// writes, and the pane reads it from there.
@MainActor
@Observable
final class HostSessions {

    /// Which of this Mac's hosts.
    let identity: HostIdentity

    init(
        identity: HostIdentity = .code,
    ) {
        self.identity = identity
    }

    private(set) var status: HostClient.Status = .idle

    /// Keyed by the host's own key for a session, which exists before the
    /// session id does — `start` answers immediately, `session.init` arrives
    /// once the SDK has opened the transcript.
    private(set) var index = HostSessionIndex()

    var asks: HostAskQueue { index.asks }
    var sessions: [String: HostSessionSummary] { index.sessions }

    /// The efforts the process now holding the socket will take. Empty until it
    /// has said hello.
    var acceptedEfforts: [String] { index.acceptedEfforts }

    /// Every output style the CLI has, once a session has been run to find out.
    var outputStyles: [String] { index.outputStyles }

    /// What Default resolves to for a directory, once asked. Nil means nobody
    /// has asked yet, which is not the same as nothing being set.
    func defaults(for cwd: String) -> HostDefaults? { index.defaults[cwd] }

    /// Why the host is unusable, when it is. Kept rather than logged: a missing
    /// node is something the person has to fix, not something to retry past.
    private(set) var unavailable: String?

    var client: HostClient?

    /// Whether a start waiting on the login shell should still go ahead when it answers.
    private var wantsStart = false
    private var probingLoginShell = false

    /// Fired whenever the host says something that could change the list, so a
    /// hosted row moves when it moves rather than at the next reconcile.
    var onChange: (() -> Void)?

    /// The event itself, for the caller that needs to know which one it was
    /// rather than that something happened — a session coming up, or failing to.
    var onEvent: ((HostEvent) -> Void)?
    /// A takeover ask answered with an allow, by whoever answered it.
    var onTakeoverAllowed: ((HostAsk) -> Void)?

    /// A request the host turned down, in its own words. Sent on rather than
    /// logged: a refusal nobody is shown is how a dial comes to look broken
    /// instead of blocked.
    ///
    /// `subject` names which control was refused. It used to be inferred, which
    /// meant one written for the mode dial: a refused effort change and a
    /// refused message both reported themselves as a permission mode.
    var onRefusal: ((_ subject: String, _ what: String, _ why: String) -> Void)?

    func rows(
        worktree: (String) -> WorktreeOrigin? = { _ in nil },
        digest: (HostSessionSummary) -> SessionDigest = { _ in SessionDigest() }
    ) -> [SessionRowModel] {
        index.rows(
            worktree: worktree, digest: digest
        )
    }

    var canRename: Bool { index.servesRename }

    var canAskSideQuestions: Bool { index.servesSideQuestions }

    var canMendMcp: Bool { index.servesMcpActions }

    /// What the host says of a session, while it is up to say it.
    func running(_ key: String) -> HostSessionSummary? {
        isRunning ? sessions[key] : nil
    }

    var isRunning: Bool {
        if case .connected = status { return true }
        return false
    }

    var ordered: [HostSessionSummary] { index.ordered }

    /// The host's own pid, off its welcome. The only thing that can name the
    /// process holding the socket: it outlives the app, so this build did not
    /// necessarily start it.
    var pid: Int? { index.hostPID }

    /// Which build that process began under, against the one on disk now.
    var sdk: HostSDK? { index.sdk }

    /// The commit the host's bundle was built from, off its welcome. Nil from a
    /// host too old to say or one run from a checkout.
    var hostBuild: String? { index.hostBuild }

    /// Whether the host says it is holding work. Nil from a host too old to say,
    /// which never reads as safe to stop.
    var hostBusy: Bool? { index.hostBusy }

    /// When this app last handed the host something to run, or something it
    /// was running for the app ended.
    @ObservationIgnored private(set) var lastWorkSent: Date?
    /// Work the host holds that neither its sessions nor its `busy` show: a
    /// start waiting on the keychain, a side question, a sign-in.
    @ObservationIgnored private(set) var workInFlight = 0
    /// The same, for work with no answer to wait for, such as an MCP login
    /// finished in the browser. Held to a deadline.
    @ObservationIgnored private var heldUntil: [String: Date] = [:]

    /// Fired as work in flight begins and ends, which moves nothing in the list.
    @ObservationIgnored var onWork: (() -> Void)?

    func holdsWork(now: Date = Date()) -> Bool {
        index.holdsWork || workInFlight > 0 || heldUntil.values.contains { $0 > now }
    }

    var lastMoved: Date? { [index.lastMoved, lastWorkSent].compactMap { $0 }.max() }

    func beginWork() {
        workInFlight += 1
        lastWorkSent = Date()
        onWork?()
    }

    func endWork() {
        workInFlight = max(0, workInFlight - 1)
        lastWorkSent = Date()
        onWork?()
    }

    /// A reply that only says the socket dropped leaves the work running on
    /// the host, so it is held for as long as the host gives it.
    func endWork(after reply: HostReply?, holding name: String, for duration: TimeInterval) {
        if reply?.error == HostClient.droppedError { hold(name, for: duration) }
        endWork()
    }

    func hold(_ name: String, for duration: TimeInterval) {
        heldUntil = heldUntil.filter { $0.value > Date() }
        heldUntil[name] = Date().addingTimeInterval(duration)
        lastWorkSent = Date()
        onWork?()
    }

    /// A fresh welcome, read as the one on connecting is.
    /// As long as the host waits on a login's browser callback.
    static let mcpLoginHold: TimeInterval = 5 * 60

    func askForWelcome() {
        guard isRunning, let client else { return }
        client.send(.hello(id: client.nextRequestID(), launches: true))
    }

    /// SIGTERMs the process holding the socket, so `HostClient` respawns it from
    /// the app's own bundle. The inverse of the relaunch's ordering, and right
    /// here for the same reason it is wrong there: the respawn is *wanted* to
    /// come from this build. The pid is verified against the host marker before
    /// the signal, since macOS reuses pids and this one rode over a socket a
    /// build ago. Returns whether a signal was sent.
    @discardableResult
    func killForReplacement() -> Bool {
        guard let pid = index.hostPID, let pid32 = Int32(exactly: pid) else { return false }
        guard let command = try? Shell.run(["ps", "-o", "command=", "-p", String(pid32)]),
            command.exitCode == 0,
            command.stdoutText.contains(RebuildCommand.hostMarker)
        else { return false }
        return kill(pid32, SIGTERM) == 0
    }

    func summary(sessionID: String) -> HostSessionSummary? {
        index.summary(sessionID: sessionID)
    }

    func lastActivityAt(key: String) -> Date { index.lastActivityAt(key: key) }

    // MARK: - Lifecycle

    func start() {
        guard client == nil else { return }
        wantsStart = true

        // The login shell can take seconds, so a start that needs it waits for it off the main actor.
        var needsLoginShell = false
        let loginPath: () -> String? = {
            if LoginShell.isProbed { return LoginShell.path() }
            needsLoginShell = true
            return nil
        }
        let location: HostLocation
        do {
            location = try self.location(loginPath: loginPath)
        } catch {
            if needsLoginShell { return startAfterProbingLoginShell() }
            unavailable = String(describing: error)
            status = .unavailable(unavailable ?? "")
            return
        }
        if needsLoginShell { return startAfterProbingLoginShell() }

        let client = HostClient(
            location: location,
            onStatus: { status in
                MainActor.assumeIsolated { self.apply(status) }
            },
            onEvent: { event in
                MainActor.assumeIsolated { self.apply(event) }
            }
        )
        self.client = client
        // Made before the socket is up, on purpose: it holds the watches, and a
        // feed opened while the host was still coming up would otherwise have
        // nothing to register them with.
        client.start()
        SessionCredential.prepare()
    }

    private func location(loginPath: () -> String?) throws -> HostLocation {
        return try HostLocation.resolve(identity: identity, loginPath: loginPath)
    }

    private func startAfterProbingLoginShell() {
        guard !probingLoginShell else { return }
        probingLoginShell = true
        Task { [weak self] in
            await Task.detached(priority: .userInitiated) { _ = LoginShell.path() }.value
            guard let self else { return }
            probingLoginShell = false
            if wantsStart { start() }
        }
    }

    func stop() {
        wantsStart = false
        client?.stop()
        client = nil
        index.clear()
        status = .idle
    }

    // MARK: - Driving a session

    /// How a start came back: the key to hold a place under, or the host's own
    /// words for why there will be no session. The reason is carried rather
    /// than dropped because a start can fail before anything of the session
    /// exists to explain itself — the host cannot find the CLI, say — and the
    /// caller is then the only thing that can say so.
    enum Launch {
        case started(String)
        case refused(String?)
        /// Held back by the app before the host heard of it; the reason is the whole sentence.
        case notSent(String)
    }

    /// `started` names the session's key before the session has said anything,
    /// so the caller can hold a place for a row that does not exist yet.
    @discardableResult
    func dispatch(
        cwd: String,
        prompt: String,
        model: String? = nil,
        permissionMode: String? = nil,
        name: String? = nil,
        outputStyle: String? = nil,
        effort: String? = nil,
        resume: String? = nil,
        key: String? = nil,
        origin: SessionOrigin? = nil,
        started: (@MainActor (Launch) -> Void)? = nil
    ) -> Bool {
        guard let client else { return false }
        beginWork()
        SessionCredential.withKey(hostTakesKey: index.takesAPIKey) { credential in
            defer { self.endWork() }
            let apiKey: String?
            switch credential {
            case .success(let key): apiKey = key
            case .failure(let error):
                started?(.notSent(error.localizedDescription))
                return
            }
            client.send(
                .start(
                    id: client.nextRequestID(),
                    cwd: cwd,
                    prompt: prompt,
                    model: model,
                    permissionMode: permissionMode,
                    name: name,
                    outputStyle: outputStyle,
                    effort: effort,
                    resume: resume,
                    key: key,
                    origin: origin,
                    apiKey: apiKey
                ),
                reply: { reply in
                    MainActor.assumeIsolated {
                        guard reply.ok, let key = reply.key else {
                            started?(.refused(reply.error))
                            return
                        }
                        started?(.started(key))
                    }
                }
            )
        }
        return true
    }

    /// Nil when there is no host to ask.
    func reply(to make: (String) -> HostRequest) async -> HostReply? {
        guard let client else { return nil }
        return await client.reply(to: make(client.nextRequestID()))
    }

    /// Tells the session that asked for a launch how it went.
    func answerLaunch(_ launchId: String, key: String? = nil, error: String? = nil) {
        guard let client else { return }
        client.send(.launched(id: client.nextRequestID(), launchId: launchId, key: key, error: error))
    }

    /// The row is stamped on the app's word, not the host's — a send queued
    /// behind a running turn produces nothing on the socket until that turn
    /// ends, and a bump that waited for the round trip would make the list
    /// feel like it dropped the message. A refusal is passed on rather than
    /// swallowed, since the stamp has already moved the row for a message
    /// that never arrived.
    func send(key: String, text: String) {
        guard let client else { return }
        client.send(
            .send(id: client.nextRequestID(), key: key, text: text),
            reply: { reply in
                MainActor.assumeIsolated {
                    guard !reply.ok else { return }
                    self.onRefusal?("Message", "the send", reply.error ?? "the host gave no reason")
                }
            }
        )
        index.touched(key: key)
        lastWorkSent = Date()
        onChange?()
    }

    func rename(
        sessionId: String,
        title: String,
        quietly: Bool = false,
        renamed: @escaping @MainActor @Sendable () -> Void
    ) {
        guard let client else { return }
        client.send(
            .rename(id: client.nextRequestID(), sessionId: sessionId, title: title),
            reply: { reply in
                MainActor.assumeIsolated {
                    guard !reply.ok else { return renamed() }
                    let why = reply.error ?? "the host gave no reason"
                    guard !quietly else { return logger.notice("naming \(sessionId, privacy: .public) failed: \(why, privacy: .public)") }
                    self.onRefusal?("Rename", "the rename", why)
                }
            }
        )
    }

    func askSideQuestion(
        key: String,
        question: String,
        history: [SideExchange],
        answered: @escaping @MainActor @Sendable (Result<String, SideQuestionRefusal>) -> Void
    ) {
        guard let client else { return answered(.failure(SideQuestionRefusal(reason: "the host isn't connected"))) }
        // `reply(to:)` rather than `send`, which drops its waiter on a disconnect
        // and would leave the card waiting on an answer that can't come.
        let request = HostRequest.side(id: client.nextRequestID(), key: key, question: question, history: history)
        beginWork()
        Task {
            let reply = await client.reply(to: request)
            endWork()
            if reply.ok, let response = reply.response { return answered(.success(response)) }
            answered(.failure(SideQuestionRefusal(reason: reply.error ?? "the host gave no reason")))
        }
    }

    func stop(key: String) {
        guard let client else { return }
        client.send(
            .stop(id: client.nextRequestID(), key: key),
            reply: { reply in
                MainActor.assumeIsolated {
                    guard !reply.ok else { return }
                    self.onRefusal?("Stop", "the stop", reply.error ?? "the host gave no reason")
                }
            }
        )
    }

    func interrupt(key: String) {
        guard let client else { return }
        client.send(.interrupt(id: client.nextRequestID(), key: key))
    }

    /// What this session has running that can be ended on its own, by the call
    /// each one came from.
    func task(key: String, toolUseID: String) -> HostTask? {
        index.task(forKey: key, toolUseID: toolUseID)
    }

    /// The whole set at once, keyed the same way, for the pane that draws a row
    /// per call rather than asking one call at a time.
    func tasks(key: String) -> [String: HostTask] {
        Dictionary(
            (index.tasks[key] ?? []).compactMap { task in task.toolUseId.map { ($0, task) } },
            uniquingKeysWith: { _, later in later }
        )
    }

    /// Ends one agent. Nothing is taken off screen here: the row goes when the
    /// transcript says the agent stopped, which is the same word that takes it
    /// off when it finishes on its own — so a stop that didn't take leaves the
    /// row spinning, which is the truth. A refusal is passed on rather than
    /// swallowed, since the button is otherwise indistinguishable from one that
    /// does nothing.
    func stopTask(key: String, taskId: String) {
        guard let client else { return }
        client.send(
            .stopTask(id: client.nextRequestID(), key: key, taskId: taskId),
            reply: { reply in
                MainActor.assumeIsolated {
                    // Not for a session that has gone in the meantime: stopping
                    // an agent and then the session it belongs to is two
                    // requests, and the first comes back refused because the
                    // second took its subject. Saying so would be complaining
                    // about the thing you just asked for.
                    guard !reply.ok, self.sessions[key] != nil else { return }
                    // Nor for a stop the turn beat to the answer. Asked as the
                    // turn is already handing itself back, `stopTask` never
                    // gets its response — the query closes first — and the
                    // agent stops anyway; the transcript records `killed` and
                    // the pane is watching that. About one run in two, so said
                    // out loud it would be an error on a button that worked.
                    // Matched on the message, which is loose, and safe to be:
                    // this only ever drops a toast. The row is drawn off the
                    // transcript, so the worst a wrong match costs is an error
                    // nobody was told about, never a row left wrong.
                    // See docs/claude-code/stopping-one-agent.md.
                    guard reply.error?.contains("Query closed") != true else { return }
                    self.onRefusal?(
                        "Stop agent", "stopping it", reply.error ?? "the host gave no reason"
                    )
                }
            }
        )
    }

    /// Nil once the CLI has the server back; otherwise why not, for the popover
    /// that asked to show beside the server.
    func reconnectMcp(key: String, server: String) async -> String? {
        guard let client else { return "the host isn't connected" }
        let reply = await client.reply(to: .mcpReconnect(id: client.nextRequestID(), key: key, server: server))
        return reply.ok ? nil : reply.error ?? "the host gave no reason"
    }

    func loginMcp(key: String, server: String) async -> Result<McpLoginStart, McpRefusal> {
        guard let client else { return .failure(McpRefusal(reason: "the host isn't connected")) }
        hold("mcp-login \(key) \(server)", for: Self.mcpLoginHold)
        let reply = await client.reply(to: .mcpLogin(id: client.nextRequestID(), key: key, server: server))
        guard reply.ok else { return .failure(McpRefusal(reason: reply.error ?? "the host gave no reason")) }
        return .success(McpLoginStart(url: reply.authUrl.flatMap(URL.init(string:)), reconnects: reply.reconnects ?? true))
    }

    /// Moves what a running session thinks at. Shown as taken at once, without
    /// waiting to be told it was taken — the round trip runs as long as the
    /// turn the session is in the middle of — and put back on a refusal:
    /// nothing restates an effort, so a refusal left standing is a badge
    /// naming a level the session never reached, for the rest of its life.
    /// Nothing while the host is down: the dial has nobody to tell.
    func setEffort(key: String, effort: String) {
        guard isRunning, let client else { return }
        let previous = index.sessions[key]?.effort
        index.moved(toEffort: effort, forKey: key)
        client.send(
            .effort(id: client.nextRequestID(), key: key, effort: effort),
            reply: { reply in
                MainActor.assumeIsolated {
                    guard !reply.ok else { return }
                    self.index.moved(toEffort: previous, forKey: key)
                    self.onRefusal?("Effort", effort, reply.error ?? "the host gave no reason")
                    self.onChange?()
                }
            }
        )
        onChange?()
    }

    /// Asks what Default means for a folder. Fire-and-forget: the answer comes
    /// back as an event, and until it does the pickers say Default and nothing
    /// more — which is what they said before any of this.
    ///
    /// Asked every time rather than once per folder. It reads files that change
    /// under the app — editing `outputStyle` in a settings file is the ordinary
    /// way to move it — and a cached answer had no way back to correct: what the
    /// index holds outlives the host on purpose, so even replacing the host left
    /// the old value on screen. A row naming the wrong Default is worse than the
    /// bare word it replaced. What it costs is a merge the host runs in-process
    /// in about 30ms, on a folder change or a window opening.
    func resolveDefaults(cwd: String) {
        guard let client else { return }
        client.send(.resolveDefaults(id: client.nextRequestID(), cwd: cwd))
    }

    // MARK: - Answering

    /// Answered against the ask the card was drawn from, not against whatever is
    /// current when the click lands: an ask withdrawn mid-read moves the queue,
    /// and answering by position would put one question's answers on another.
    func answer(
        askId: String,
        answers: [String: HostAnswerValue],
        notes: [String: String] = [:]
    ) {
        guard let client, index.asks.pending.contains(where: { $0.askId == askId }) else { return }
        client.send(
            .answerQuestion(
                id: client.nextRequestID(),
                askId: askId,
                answers: answers,
                notes: notes
            )
        )
        index.answered(askId)
    }

    /// Said instead of answering: the CLI reads this as the whole of the reply
    /// and writes a result carrying nothing else, so the picks the card was
    /// holding are not sent with it and the ask is done either way.
    func respond(askId: String, text: String) {
        guard let client, index.asks.pending.contains(where: { $0.askId == askId }) else { return }
        client.send(
            .answerQuestion(
                id: client.nextRequestID(),
                askId: askId,
                answers: [:],
                response: text
            )
        )
        index.answered(askId)
    }

    func answer(askId: String, option: HostAskOption) {
        guard let client, let ask = index.asks.pending.first(where: { $0.askId == askId })
        else { return }
        client.send(
            .answerPermission(id: client.nextRequestID(), askId: askId, optionId: option.optionId)
        )
        index.answered(askId)
        // Whichever way it was allowed — from the card or by the app on its
        // own — the session now has the screen, and one place says so.
        if ask.kind == .takeover, option.kind.isAllow { onTakeoverAllowed?(ask) }
    }

    /// Denied, with what was typed as the reason — which the sidecar sends on as
    /// the denial's message, and is the whole of what the model gets in place of
    /// the result. Refused by the ask's own option, falling back to the id the
    /// host names refusals by; anything that isn't a recognised allow is read as
    /// a denial at the other end, so the fallback cannot come out an approval.
    func deny(askId: String, message: String) {
        guard let client, let ask = index.asks.pending.first(where: { $0.askId == askId })
        else { return }
        client.send(
            .answerPermission(
                id: client.nextRequestID(),
                askId: askId,
                optionId: ask.options.first { !$0.kind.isAllow }?.optionId
                    ?? HostAskOptionKind.rejectOnce.raw,
                message: message
            )
        )
        index.answered(askId)
    }

    // MARK: - Applying what the host says

    private func apply(_ status: HostClient.Status) {
        self.status = status
        switch status {
        case .unavailable(let reason):
            unavailable = reason
        case .connected:
            unavailable = nil
        default:
            unavailable = nil
        }
    }

    private func apply(_ event: HostEvent) {
        // An older host still sends `session.writing` several times a second.
        if case .unrecognised = event { return }
        index.apply(event)
        onEvent?(event)
        onChange?()
    }
}

struct SideQuestionRefusal: Error {
    let reason: String
}

struct McpRefusal: Error {
    let reason: String
}

struct McpLoginStart {
    /// Nil where the CLI needed nothing from anyone.
    let url: URL?
    let reconnects: Bool
}
