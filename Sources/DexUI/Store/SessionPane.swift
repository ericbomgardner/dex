import DexCore
import Foundation
import Observation

/// The session attached in the window's right-hand pane.
@MainActor
@Observable
package final class SessionPane {
    /// Set by the store, which owns both panes: the host facts about the
    /// attached session live there, and the pane speaks for one session at a
    /// time.
    weak var context: (any PaneContext)?

    private(set) var attachment: PaneAttachment? {
        didSet { if oldValue?.hostKey != attachment?.hostKey { openAgents = [] } }
    }

    /// The agents being read over the transcript, outermost first. Each one
    /// after the first was opened from inside the one before it.
    private(set) var openAgents: [OpenAgent] = []

    /// A session dispatched but not yet in the list, holding the pane until it
    /// has a row of its own to attach to.
    private(set) var starting: PendingDispatch?

    /// What the transcript's composer has typed but not sent, and whatever was
    /// dropped on it, kept against the session it was meant for. Held here so
    /// looking at another session and coming back doesn't cost you the message.
    private var drafts: ComposerDrafts {
        didSet { Defaults.paneDrafts = drafts }
    }

    var draft: String {
        get { attachment.map { drafts[$0.hostKey] } ?? "" }
        set {
            guard let attachment else { return }
            drafts[attachment.hostKey] = newValue
        }
    }

    var attachments: [ComposerAttachment] {
        get { attachment.map { drafts.attachments(for: $0.hostKey) } ?? [] }
        set {
            guard let attachment else { return }
            drafts.setAttachments(newValue, for: attachment.hostKey)
        }
    }

    func attach(_ dropped: [ComposerAttachment]) {
        attachments = ComposerAttachments.adding(dropped, to: attachments)
    }

    func detach(_ dropped: ComposerAttachment) {
        attachments.removeAll { $0 == dropped }
    }

    /// Puts a message that never arrived back where it was written. Aimed by
    /// key rather than at the open pane, since what failed may not be what you
    /// are looking at by the time it does; and anything already in the box is
    /// newer than this and keeps the spot.
    func restore(draft text: String, for key: String, unsaying said: [String] = []) {
        // Nothing stands in for a message that is back in the box. Only the
        // ones handed back, though: another may have gone out by a route this
        // failure says nothing about, and be on its way into the file still.
        // Matched on the text, which is safe here in a way it isn't against a
        // transcript — both sides are the app's own copy of what was sent.
        if !said.isEmpty {
            let handed = Set(said)
            let left = saying[key]?.filter { !handed.contains($0.text) } ?? []
            saying[key] = left.isEmpty ? nil : left
        }
        guard ComposerDraft.persistable(drafts[key]) == nil else { return }
        drafts[key] = text
    }

    init() {
        drafts = Defaults.paneDrafts
    }

    /// Counted from the moment a session is dispatched, so the column is sized
    /// for the pane it is about to hold rather than widening again underneath it.
    var isOpen: Bool { attachment != nil || starting != nil }

    /// Takes the pane the way attaching does, viewer and all: this is a switch.
    func start(_ pending: PendingDispatch) {
        attachment = nil
        starting = pending
    }

    /// By id, so a dispatch that gives up late doesn't clear the pane a later
    /// one has already claimed.
    func stopStarting(_ id: UUID) {
        guard starting?.id == id else { return }
        starting = nil
    }

    func open(_ wanted: PaneAttachment) {
        starting = nil
        guard attachment?.hostKey != wanted.hostKey else { return }
        attachment = wanted
    }

    /// A pane attached before the SDK opened the transcript has no id to read
    /// it by, and `open` treats the same session as already attached — so the
    /// id is adopted in place when the row learns it.
    func adopt(sessionID: String) {
        guard let attachment, attachment.sessionID == nil else { return }
        self.attachment = attachment.adopting(sessionID: sessionID)
    }

    /// Leaves a session on its way alone: closing the pane lets go of what it
    /// holds, and one that hasn't arrived isn't that.
    func close() {
        attachment = nil
    }

    /// A forgotten session takes what was typed at it with it, and the pane if it was open.
    func forget(key: String) {
        drafts[key] = ""
        drafts.setAttachments([], for: key)
        saying[key] = nil
        if attachment?.hostKey == key { close() }
    }

    /// What has been said to a session and not yet read back out of its
    /// transcript, oldest first, per session.
    ///
    /// The file is the app's only word for what a session has been told, and it
    /// is a second or two behind — longer when the message is what resumes the
    /// session, since a CLI has to start before anything is written at all. For
    /// that stretch the message was nowhere: the box had emptied, the
    /// transcript was unchanged, and the only thing on screen about it was that
    /// nothing had happened. So the pane holds it and draws it where it will
    /// land, from the moment it is sent.
    private(set) var saying: [String: [Said]] = [:]

    /// A message the pane is standing in for. Identified by nothing the session
    /// will ever echo back — what it is matched against is arrival, not
    /// identity, since the CLI rewrites what it records (a slash command is not
    /// the line you typed) and a text comparison that misses would leave the
    /// message on screen twice for good.
    package struct Said: Identifiable, Equatable {
        package let id = UUID()
        let text: String
        /// Sent into a turn already running, so the session holds it without
        /// having got to it; drawn under the work rather than over it. One
        /// sent to an idle session is what starts the turn and goes above.
        let intoTurn: Bool
    }

    func saying(for key: String?) -> [Said] {
        key.flatMap { saying[$0] } ?? []
    }

    /// The same, against what the file has caught up on as of right now. Asked
    /// rather than left to the bookkeeping below, which runs after the frame it
    /// would have corrected: the prompt and the pane's stand-in for it come off
    /// the same reading, so for one frame the message would be on screen twice.
    func saying(for key: String?, heard total: Int, of transcript: String?) -> [Said] {
        guard let key else { return [] }
        return Array(saying(for: key).dropFirst(arrived(total, of: transcript, for: key)))
    }

    /// What the file has caught up on: prompts written, plus messages the
    /// session has put in its queue, which is the same message arriving by the
    /// other door. Anything past the most it has ever had is a message the pane
    /// no longer has to stand in for, oldest first — the order they were sent
    /// in and the order they are written in.
    ///
    /// The most that transcript has ever had, rather than the last count seen,
    /// because the feed starts every file from nothing and climbs: re-reading
    /// one — which is what following a session that changed directory does —
    /// would otherwise have the climb read as its messages arriving, and drop
    /// what it was standing in for while the file was still empty.
    ///
    /// Which is why the mark is kept against the transcript it was taken from
    /// rather than against the key alone. A key outlives the session that used
    /// it — one that ends frees it, and a new session can start under it — and
    /// a mark left over from a conversation fifty prompts long would sit above
    /// anything a new file could reach, so nothing said to it would ever be let
    /// go of. A transcript the mark was not taken from is marked afresh and
    /// lets nothing go, which is what the first reading of any file does.
    func heard(_ total: Int, of transcript: String?, for key: String) {
        let landed = arrived(total, of: transcript, for: key)
        let mark = marks[key].flatMap { $0.transcript == transcript ? $0.count : nil } ?? total
        marks[key] = Mark(transcript: transcript, count: max(mark, total))
        guard landed > 0, var waiting = saying[key] else { return }
        waiting.removeFirst(min(landed, waiting.count))
        saying[key] = waiting.isEmpty ? nil : waiting
    }

    /// How much of what is being stood in for the file has since caught up on.
    /// Nothing at all until a first reading of that file has set the mark,
    /// which is what makes that reading a mark rather than an arrival.
    private func arrived(_ total: Int, of transcript: String?, for key: String) -> Int {
        guard let mark = marks[key], mark.transcript == transcript, total > mark.count else {
            return 0
        }
        return total - mark.count
    }

    /// The high-water mark of the above, and the file it was taken from.
    private var marks: [String: Mark] = [:]

    private struct Mark {
        let transcript: String?
        let count: Int
    }

    /// How many times the reader has spoken to the session from this pane.
    /// Read by the transcript, which needs it for the one thing its own
    /// geometry cannot tell it: somebody who has just typed is at the end of
    /// the conversation, wherever the pane happens to be sitting.
    private(set) var sends = 0

    /// Outside observation: it is written on every scroll.
    @ObservationIgnored let places = TranscriptPlaces()

    /// Said something to the session. Called by the composer for an answer to
    /// an ask as well as for a message, since either is the reader speaking.
    func spoke() {
        sends += 1
    }

    /// Side questions, per session. Kept in memory only: nothing about one is in
    /// the transcript, and it isn't meant to outlast the moment it was asked in.
    var asides: [String: Aside] = [:]

    /// Per session, the newest drop each MCP server had when it was reconnected
    /// from here. A drop read off the transcript stays newest until another call
    /// is answered, so without this the chip would outlive the fix.
    var mcpReconnected: [String: [String: Date]] = [:]

    /// Servers whose login finished somewhere the CLI never hears about.
    /// Kept here rather than in the popover, which closes as the
    /// browser comes forward.
    var mcpAwaitingReconnect: [String: Set<String>] = [:]

    /// Set by the store: how a session is spoken to, since this type has no way
    /// to reach the host itself.
    var hostSend: ((_ key: String, _ text: String) -> Void)?

    /// The session is handed the message and that is the whole of it — no paste,
    /// no return, nothing to read back. The field is yours again at once.
    /// `explicit` is for a message that went out late, and leaves alone
    /// whatever is in the field by then.
    func send(_ message: String, intoTurn: Bool = false, to explicit: String? = nil) {
        let open = attachment?.hostKey
        guard let key = explicit ?? open, ComposerDraft.persistable(message) != nil
        else { return }
        if explicit == nil { clear() }
        if key == open { spoke() }
        saying[key, default: []].append(Said(text: message, intoTurn: intoTurn))
        hostSend?(key, message)
    }

    /// The paths went out folded into the message, so the chips have said their
    /// piece and go with the text.
    func clear() {
        draft = ""
        attachments = []
    }
}

/// What a pane needs of whoever holds the hosts and the list: the store.
@MainActor
protocol PaneContext: AnyObject {
    func row(forKey key: String) -> SessionRowModel?
    /// The host holding a key, which is this Mac's for nil or a key nothing holds.
    func host(holding key: String?) -> HostSessions
    func isArchived(key: String) -> Bool
    func launchedModel(forKey key: String) -> SessionModel?
    /// The open session's dial moved.
    func effortChanged(_ effort: EffortLevel, forKey key: String)
}

/// What the pane asks of the host about the session it is attached to. Off
/// the store, which holds the hosts, keyed by whatever this pane has open.
extension SessionPane {
    private var key: String? { attachment?.hostKey }

    /// The list row behind the open pane, so the pane can say what the list
    /// already says about the session.
    var row: SessionRowModel? {
        guard let key, let context else { return nil }
        return context.row(forKey: key)
    }

    /// Whether the host is holding the open pane's session, and so has a turn of
    /// its own to cut short. Its own sessions only: a transcript found on disk
    /// reads as working the same way and has nobody on the other end to tell.
    var isHosted: Bool {
        guard let key, let context else { return false }
        return context.host(holding: key).sessions[key] != nil
    }

    /// Whether the open pane is a conversation the host no longer holds and the
    /// app can still pick up.
    var awaitsResume: Bool {
        guard let key, let context else { return false }
        return context.host(holding: key).sessions[key] == nil
            && context.isArchived(key: key)
    }

    /// Whether to offer the stop button, which follows the working line rather
    /// than the socket: the two say the same thing about the session, and a
    /// button standing where the pane shows nothing happening reads as a bug.
    /// Not while the session is only waiting on background work, though —
    /// interrupt cuts a turn, and there is no turn; what's running has its own
    /// Stop where the app can name it.
    var turnIsInterruptible: Bool {
        guard isHosted, let row else { return false }
        return row.isActivelyWorking() && !row.isAwaitingBackgroundWork
    }

    /// The agent that call is still running, where the host is holding this
    /// session and knows of one. Nil is the ordinary answer for an agent this
    /// app didn't watch start — a session found on disk, or one whose agent was
    /// already out when the app connected — and means there is nothing to press.
    func agentTask(toolUseID: String) -> HostTask? {
        guard let key, let context else { return nil }
        return context.host(holding: key).task(key: key, toolUseID: toolUseID)
    }

    /// Every agent the host says the attached session still has out, keyed by
    /// the call that spawned each. The task id doubles as the agent's own
    /// transcript name, which is what lets a delegating row open onto a
    /// foreground agent's conversation while it runs — the transcript's name
    /// for it arrives only with the result.
    var runningAgents: [String: String] {
        guard let key, let context else { return [:] }
        return context.host(holding: key).tasks(key: key).mapValues(\.taskId)
    }

    /// Ends one agent and leaves the session working. The turn's Stop is the
    /// blunt instrument beside it: it ends everything, including the agents the
    /// turn is waiting on.
    func stopAgent(taskID: String) {
        guard let key, let context else { return }
        context.host(holding: key).stopTask(key: key, taskId: taskID)
    }

    /// Ends the turn, not the session. The conversation stays open and the CLI
    /// writes the interruption into the transcript, so what was said before it
    /// is still there to pick up from.
    ///
    /// Deliberately a weaker test than the button's: the state is late to say a
    /// turn has started, and an opening think long enough to go quiet would take
    /// the key away exactly where it is wanted. Since CLI v2.1.261 an interrupt
    /// sent before the turn has started stops it instead of being absorbed, so
    /// this is a real stop on the opening turn too, not a harmless no-op.
    func interrupt() {
        guard isHosted, let key, let context else { return }
        context.host(holding: key).interrupt(key: key)
    }

    var mcpTrouble: [McpTrouble] {
        guard let key, let row else { return [] }
        return row.mcpTrouble(reconnected: mcpReconnected[key] ?? [:])
    }

    /// Whether the chip's Reconnect and Log in can reach anything: the host
    /// must hold the session and be new enough to have the requests.
    var canMendMcp: Bool {
        guard isHosted, let context else { return false }
        return context.host(holding: key).canMendMcp
    }

    func awaitsMcpReconnect(_ server: String) -> Bool {
        key.map { mcpAwaitingReconnect[$0]?.contains(server) == true } ?? false
    }

    func reconnectMcp(_ trouble: McpTrouble) async -> String? {
        guard let key, let context else { return "no session is open" }
        if let refusal = await context.host(holding: key).reconnectMcp(key: key, server: trouble.server) {
            return refusal
        }
        mcpReconnected[key, default: [:]][trouble.server] = trouble.droppedAt ?? .distantPast
        mcpAwaitingReconnect[key]?.remove(trouble.server)
        return nil
    }

    func loginMcp(_ server: String) async -> Result<McpLoginStart, McpRefusal> {
        guard let key, let context else { return .failure(McpRefusal(reason: "no session is open")) }
        let result = await context.host(holding: key).loginMcp(key: key, server: server)
        if case .success(let start) = result, !start.reconnects {
            mcpAwaitingReconnect[key, default: []].insert(server)
        }
        return result
    }

    func openAgent(_ call: ToolCall, agentID: String, nested: Bool) {
        let opened = OpenAgent(call: call, agentID: agentID)
        if nested {
            guard openAgents.last?.call.id != call.id else { return }
            openAgents.append(opened)
        } else {
            openAgents = [opened]
        }
    }

    /// Back out to the agent at `level`, closing everything opened inside it.
    func backOutAgents(to level: Int) {
        openAgents = Array(openAgents.prefix(level + 1))
    }

    func closeAgents() {
        openAgents = []
    }

    var aside: Aside? { key.flatMap { asides[$0] } }

    func askAside(_ question: String) {
        guard let key, let context else { return }
        var aside = asides[key] ?? Aside()
        let id = aside.ask(question)
        let history = aside.exchanges
        asides[key] = aside

        let holder = context.host(holding: key)
        let refusal: String? =
            if !isHosted { "Only a session Dex is running can take a side question." }
            else if !holder.canAskSideQuestions { "This host is too old for side questions. Restart it to pick up the new one." }
            else { nil }
        if let refusal {
            asides[key]?.failed(id, because: refusal)
            return
        }

        holder.askSideQuestion(key: key, question: question, history: history) { [weak self] result in
            switch result {
            case .success(let response): self?.asides[key]?.answered(id, with: response)
            case .failure(let refusal): self?.asides[key]?.failed(id, because: refusal.reason)
            }
        }
    }

    func closeAside() {
        guard let key else { return }
        asides[key] = nil
    }

    /// Hands the aside to the session after all, by way of the draft so it can
    /// be cut down or added to first.
    func draftAside() {
        guard let quoted = aside?.quoted, !quoted.isEmpty else { return }
        draft = draft.isEmpty ? quoted : draft + "\n\n" + quoted
        closeAside()
    }

    /// What the host will take on an `effort` request for the attached session.
    var acceptedEfforts: [String] {
        guard let context else { return [] }
        return context.host(holding: key).acceptedEfforts
    }

    /// The pane's dial reads Default off the session's own folder.
    func readDefaults(for cwd: String) {
        guard let context else { return }
        context.host(holding: key).resolveDefaults(cwd: cwd)
    }

    /// What Default means for the attached session, read off the folder it was
    /// started in rather than off the session. The session cannot be asked: what
    /// the app sent it rides above every file behind this answer, so a session's
    /// own reading would say what was picked, not what picking nothing means.
    var defaults: HostDefaults? {
        guard let row, let context else { return nil }
        return context.host(holding: row.rowID).defaults(for: row.projectPath)
    }

    /// The id the CLI resolved at init, for the stretch before a first reply
    /// has written it into the transcript — which for a thinking model is the
    /// whole opening wait. Default rows too: init names what Default resolved
    /// to, which the launch alias never could.
    var resolvedModel: String? {
        guard let key, let context else { return nil }
        return context.host(holding: key).running(key)?.model
    }

    /// What the session was launched as, for the beat before init has said.
    /// Only while the host still holds the session: an archived pane's chip is
    /// the transcript's alone.
    var launchedModel: SessionModel? {
        guard let key, let context else { return nil }
        let running = context.host(holding: key).running(key)
        return running == nil ? nil : context.launchedModel(forKey: key)
    }

    /// What the attached session thinks at, when the host is still holding it
    /// and something has said. Nil where nobody asked: the settings files
    /// resolved a level and neither the host nor this app can read it back.
    var effort: EffortLevel? {
        guard let key, let context else { return nil }
        return context.host(holding: key).running(key)
            .flatMap { EffortLevel(stored: $0.effort) }
    }

    func setEffort(_ effort: EffortLevel) {
        guard let key, let context, let name = effort.hostEffortID else { return }
        context.host(holding: key).setEffort(key: key, effort: name)
        context.effortChanged(effort, forKey: key)
    }
}

/// A delegating call and the agent it set off, as it was when it was opened.
struct OpenAgent: Hashable {
    let call: ToolCall
    let agentID: String
}
