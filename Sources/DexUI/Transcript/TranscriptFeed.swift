import DexCore
import Foundation
import Observation

/// Follows one session's transcript file and publishes what it has read.
///
/// Driven by `.task(id:)`, so switching sessions or closing the pane cancels the
/// loop; nothing else has to remember to stop it.
@MainActor
@Observable
package final class TranscriptFeed {

    enum Phase: Sendable, Hashable {
        case looking
        /// Found, and the first pass over it not yet landed. Drawn as nothing,
        /// since it lasts a read and a glyph that comes and goes in that time
        /// is the flash a switch is meant not to have.
        case opening
        case reading
        case unavailable
    }

    package private(set) var items: [TranscriptItem] = []
    private(set) var phase: Phase = .looking

    /// Sent, and waiting on the turn the session is in the middle of.
    private(set) var queued: [QueuedMessage] = []

    /// Off the queue and not yet written — see `TranscriptDocument.taken`.
    private(set) var taken: [QueuedMessage] = []

    /// How much of what has been said to this session the file has caught up
    /// on, off the document — see `TranscriptDocument.heard`.
    private(set) var heard = 0

    /// Which transcript `heard` was counted from. One feed outlives a switch
    /// between sessions, so for the frame after one the count above still
    /// belongs to the transcript before — and a reader pairing it with the
    /// session now attached marks that session at another's count.
    package private(set) var heardOf: String?

    /// What the session is answering as. Nil until a reply has been written.
    private(set) var model: String?

    /// What it is carrying, off the same turn.
    private(set) var context: SessionContext?

    /// When the newest turn was handed over, for the clock over the composer.
    private(set) var handedOverAt: Date?

    /// When this run began and when its first items landed, for the timing
    /// lines the pane logs on a switch.
    private(set) var switchedAt: ContinuousClock.Instant?
    private(set) var firstItemsAt: ContinuousClock.Instant?

    /// What to say the session is carrying, with the list's own reading of the
    /// same file standing in until this one has read it. The feed starts every
    /// transcript from nothing and takes passes to reach the newest turn, while
    /// the row beside it has already read that same usage off the end of that
    /// same file — so the badge was absent for a stretch where the number was
    /// sitting in the list, and arrived by shoving the chips along.
    ///
    /// Not once the file has been given up on, though. The list keeps its last
    /// digest when a locate fails and nothing ever clears it, so a session whose
    /// transcript can no longer be found would wear a frozen number under a pane
    /// already saying there is nothing to read.
    func carrying(orListsWord list: SessionContext?) -> SessionContext? {
        if let context { return context }
        return phase == .unavailable ? nil : list
    }

    /// What to say the session is answering as, with the same stand-in: the
    /// model rides on the same turn the list read its usage off, and the pill
    /// blinked out on every switch for exactly the stretch the badge used to.
    func answering(orListsWord list: String?) -> String? {
        if let model { return model }
        return phase == .unavailable ? nil : list
    }

    /// Where this session's agents write, derived from the transcript actually
    /// opened rather than from the session id — a session that moved takes its
    /// transcript with it, and its agents' files go along.
    private(set) var subagents: String?

    /// What a run has read of a session, so that coming back to it draws the
    /// conversation at once and reads only what was written since. Filed after
    /// every pass rather than as the run ends: a switch starts the next run
    /// before the last one has woken to notice it was cancelled, so a switch
    /// straight back found nothing filed and read the whole file again.
    /// Bounded, since a document holds every tool result in the file.
    private struct Kept {
        var path: String
        var offset: Int
        var document: TranscriptDocument
        var items: [TranscriptItem]
        var subagents: String?
        var filedAt: ContinuousClock.Instant
    }

    private var kept: [String: Kept] = [:]

    package init() {}
    private static let keeps = 10

    /// Given the run's own items rather than read off the feed: one feed
    /// outlives a switch, and a run ending late — after a read that outlasted
    /// the switch — would otherwise file the next session's conversation under
    /// its own.
    private func keep(
        _ sessionID: String?, path: String?, offset: Int,
        document: TranscriptDocument, items: [TranscriptItem], subagents: String?
    ) {
        guard let sessionID, let path, !items.isEmpty else { return }
        kept[sessionID] = Kept(
            path: path, offset: offset, document: document, items: items,
            subagents: subagents, filedAt: .now
        )
        while kept.count > Self.keeps, let oldest = kept.min(by: { $0.value.filedAt < $1.value.filedAt }) {
            kept.removeValue(forKey: oldest.key)
        }
    }

    /// Long enough not to spin, short enough that a reply lands about when the
    /// terminal would have shown it.
    private static let interval = Duration.milliseconds(600)

    /// A session that has never written a transcript is usually still starting.
    /// After this the pane says so rather than spinning forever.
    private static let patience = Duration.seconds(20)

    package func run(sessionID: String?, source: any TranscriptSource = LocalTranscriptSource()) async {
        items = []
        queued = []
        taken = []
        heard = 0
        heardOf = nil
        model = nil
        context = nil
        handedOverAt = nil
        subagents = nil
        phase = .looking
        switchedAt = .now
        firstItemsAt = nil

        var path: String?
        var offset = 0
        var document = TranscriptDocument()
        var shown: [TranscriptItem] = []
        var beside: String?
        var locateTook: Duration = .zero
        let startedAt = ContinuousClock.now
        let wake = TranscriptWake()
        defer { wake.stop() }

        if let sessionID, let back = kept[sessionID] {
            path = back.path
            offset = back.offset
            document = back.document
            shown = back.items
            beside = back.subagents
            items = back.items
            queued = document.queued
            taken = document.taken
            heard = document.heard
            heardOf = sessionID
            model = document.model
            context = document.context
            handedOverAt = document.handedOverAt
            subagents = back.subagents
            phase = .reading
            firstItemsAt = .now
            wake.follow(source.changes(to: back.path))
        }

        while !Task.isCancelled {
            if path == nil {
                let asked = ContinuousClock.now
                if let sessionID, let found = await source.locate(sessionID: sessionID) {
                    locateTook = ContinuousClock.now - asked
                    path = found
                    offset = 0
                    beside = source.subagentDirectory(besideParent: found)
                    subagents = beside
                    wake.follow(source.changes(to: found))
                    phase = .opening
                } else if ContinuousClock.now - startedAt > Self.patience {
                    // Kept from a run before the file went for good, this
                    // would otherwise stand for a transcript that no longer
                    // exists, in front of the line that says so.
                    items = []
                    shown = []
                    phase = .unavailable
                    if let sessionID { kept[sessionID] = nil }
                }
            }

            if let reading = path {
                let pass = await Self.read(reading, from: offset, through: source, into: document)
                // A switch cancels this run and starts the next on the same
                // feed; a read that finishes after that belongs to the last
                // session and would draw it under the new one.
                guard !Task.isCancelled else { return }
                if !Task.isCancelled, firstItemsAt == nil, !pass.read.vanished,
                   pass.items?.isEmpty == false {
                    firstItemsAt = .now
                    let session = String((sessionID ?? "?").prefix(8))
                    let locate = Timing.ms(locateTook), waited = Timing.ms(pass.waited)
                    let inside = Timing.ms(pass.read.took), parse = Timing.ms(pass.parseTook)
                    let flow = Timing.ms(pass.flowTook), items = Timing.ms(firstItemsAt! - startedAt)
                    let lines = pass.read.lines.count, count = pass.items?.count ?? 0
                    Timing.logger.notice(
                        "switch \(session, privacy: .public): locate \(locate, privacy: .public), read \(waited, privacy: .public) (\(inside, privacy: .public) inside), parse \(parse, privacy: .public), flow \(flow, privacy: .public), items \(items, privacy: .public) after switch; \(lines) lines, \(count) items"
                    )
                }
                if pass.read.vanished {
                    // A session that changes directory takes its transcript with
                    // it, so the path we opened stops being the one written to.
                    // Looking again finds where it went; what we have on screen
                    // stands until the new file has been read — including where
                    // this session's agents were, since dropping that shuts every
                    // open agent row and starts its reading again from nothing.
                    path = nil
                    wake.stop()
                    document = TranscriptDocument()
                } else {
                    offset = pass.read.offset
                    document = pass.document
                    phase = .reading
                    if let read = pass.items {
                        shown = read
                        items = read
                        queued = pass.document.queued
                        taken = pass.document.taken
                        heard = pass.document.heard
                        heardOf = sessionID
                        model = pass.document.model
                        context = pass.document.context
                        handedOverAt = pass.document.handedOverAt
                        phase = .reading
                    }
                    keep(sessionID, path: path, offset: offset, document: document, items: shown, subagents: beside)
                }
            }

            await wake.wait(upTo: source.interval)
        }
    }

    private struct Pass: Sendable {
        let read: TranscriptRead
        let document: TranscriptDocument
        /// Nil when the file has not grown, so an idle session redraws nothing.
        let items: [TranscriptItem]?
        let waited: Duration
        let parseTook: Duration
        let flowTook: Duration
    }

    // Off the main actor: the parse and the item build take a beat on a long
    // transcript, and the pane has nothing to draw until both are done.
    nonisolated private static func read(
        _ path: String,
        from offset: Int,
        through source: any TranscriptSource,
        into document: TranscriptDocument
    ) async -> Pass {
        let asked = ContinuousClock.now
        let read = await source.read(path, from: offset)
        let waited = ContinuousClock.now - asked
        var document = document
        if read.restarted { document = TranscriptDocument() }
        let parsing = ContinuousClock.now
        for line in read.lines { document.append(line: line) }
        let parseTook = ContinuousClock.now - parsing

        let changed = read.restarted || !read.lines.isEmpty
        let flowing = ContinuousClock.now
        let items = changed ? TranscriptFlow.items(from: document.entries) : nil
        return Pass(
            read: read,
            document: document,
            items: items,
            waited: waited,
            parseTook: parseTook,
            flowTook: ContinuousClock.now - flowing
        )
    }
}
