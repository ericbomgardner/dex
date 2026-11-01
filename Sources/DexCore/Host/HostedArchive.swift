import Foundation

/// The hosted sessions this app has seen, kept so a row outlives the host that
/// was running it.
///
/// A hosted session has no job file and no process of its own, so the host's own
/// list was the whole of the app's account of one: kill the host and every row
/// went with it mid-sentence, taking the transcript you were reading and
/// whatever you had said about it. The conversation was never the thing that
/// died — it is on disk throughout, under the same id the pane already reads it
/// by. This is what remembers where to find it, what it was called, and what to
/// ask for to pick it up again.
///
/// Keyed by the host key rather than by the transcript id, because that is what
/// the list names a row by. It is also what the session is asked to come back
/// under, so a resumed conversation is the row it was rather than a stranger
/// arriving beside it.
public struct HostedArchive: Codable, Hashable, Sendable {

    /// How long a session nobody has touched stays in the list. Nothing else
    /// here ages out — the CLI retires its own rows and this has no equivalent,
    /// so without a window every hosted session ever run would be a row forever.
    public static let keepFor: TimeInterval = 7 * 24 * 60 * 60

    /// Bounds what a single defaults blob can grow to. Newest kept, since the
    /// window already means anything near the cap is recent.
    public static let capacity = 250

    /// How far the clock may drift before the record is rewritten. A live
    /// session's clock is the host's business — this one is only read once the
    /// host no longer has it — and the host mentions a busy session constantly,
    /// so writing the whole archive out for each mention is an encode of every
    /// session ever, on the main actor, several times a turn, to move one date
    /// by a second. Half a minute is well inside what the sort and the
    /// resolution mark can tell apart.
    public static let clockQuantum: TimeInterval = 30

    public struct Entry: Codable, Hashable, Sendable {
        public var key: String
        /// Both what the pane reads and what a resume asks for. An entry cannot
        /// exist without one: a session that never reached `session.init` wrote
        /// no transcript, so there is nothing to come back to.
        public var sessionId: String
        public var cwd: String
        /// What the row says, kept rather than re-read. Nothing writes to a
        /// stopped session's transcript, so a row that read the file again on
        /// every pass would be paying a directory scan per session per ten
        /// seconds to be told the same two lines.
        public var name: String?
        public var lastMessage: String?
        public var model: String?
        /// What it was thinking at, so a resume can ask for it again. The
        /// launch flag is the only place this can come from: sending nothing
        /// leaves the settings cascade to answer, which brought a session
        /// started at `low` back at whatever `effortLevel` a file happened to
        /// say. Nil where nothing ever named one, which is Default and is asked
        /// for by sending nothing.
        public var effort: String?
        /// How it was writing, for the same reason: asking for nothing on the
        /// resume hands the answer to the settings cascade, and a conversation
        /// that changes voice mid-thread has nothing on screen to explain it. A
        /// running session's style *can* be moved since CLI v2.1.278, but the
        /// app offers no dial for it, so the resume is still the only moment
        /// there is to ask. The CLI's own resolved name, off `session.init`,
        /// since a name matching no file lands somewhere else and that is where
        /// it landed.
        public var outputStyle: String?
        /// What the session was carrying when it stopped. Kept for the same
        /// reason the row is: reopening a session that had grown expensive is
        /// exactly the decision this is meant to inform, and nothing writes to
        /// the file to say so once the host has let it go.
        public var context: SessionContext?
        /// Optional, so an archive written before the field decodes.
        public var origin: SessionOrigin?
        public var permissionMode: String
        public var startedAt: String
        public var lastActivityAt: Date
        /// The last time the host mentioned it.
        public var recordedAt: Date?

        public init(
            key: String,
            sessionId: String,
            cwd: String,
            name: String? = nil,
            lastMessage: String? = nil,
            model: String? = nil,
            effort: String? = nil,
            outputStyle: String? = nil,
            context: SessionContext? = nil,
            origin: SessionOrigin? = nil,
            permissionMode: String = "default",
            startedAt: String,
            lastActivityAt: Date
        ) {
            self.key = key
            self.sessionId = sessionId
            self.cwd = cwd
            self.name = name
            self.lastMessage = lastMessage
            self.model = model
            self.effort = effort
            self.outputStyle = outputStyle
            self.context = context
            self.origin = origin
            self.permissionMode = permissionMode
            self.startedAt = startedAt
            self.lastActivityAt = lastActivityAt
        }

        func differsOnlyInClock(from other: Entry) -> Bool {
            var mine = self
            mine.lastActivityAt = other.lastActivityAt
            mine.recordedAt = other.recordedAt
            return mine == other
        }
    }

    var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    public var isEmpty: Bool { entries.isEmpty }
    public var stored: [String: Entry] { entries }

    public func entry(key: String) -> Entry? { entries[key] }

    /// Written down every time the host mentions a session, so the last thing
    /// recorded is what the row falls back to. A session with no transcript id
    /// is skipped rather than half-recorded.
    ///
    /// The digest is the live row's own, taken rather than re-read: it is the
    /// transcript's title where the CLI has written one, and nothing until then,
    /// which is the difference between a remembered row keeping its name and
    /// reverting to the placeholder a session wears before it has one.
    public mutating func record(
        _ summary: HostSessionSummary,
        digest: SessionDigest = SessionDigest(),
        lastActivityAt: Date
    ) {
        guard let sessionId = summary.sessionId else { return }
        let existing = entries[summary.key]
        var candidate = Entry(
            key: summary.key,
            sessionId: sessionId,
            cwd: summary.cwd,
            // Last on both counts, or a reading that came back empty walks a
            // named row back to whatever it was called before the CLI named it.
            name: digest.title ?? entries[summary.key]?.name ?? summary.name,
            lastMessage: digest.lastMessage ?? entries[summary.key]?.lastMessage,
            model: summary.model,
            // Last named wins, for the reason the name above keeps its own: a
            // host too old to say leaves the level nil, and a resume that read
            // that would send the session somewhere it had never been.
            effort: summary.effort ?? existing?.effort,
            outputStyle: summary.outputStyle ?? existing?.outputStyle,
            context: digest.context ?? entries[summary.key]?.context,
            // A resume is started by the app, which sends no origin.
            origin: summary.origin ?? existing?.origin,
            permissionMode: summary.permissionMode,
            startedAt: summary.startedAt,
            lastActivityAt: lastActivityAt
        )
        candidate.recordedAt = lastActivityAt

        // Nothing but the clock, and barely that: left to rewrite, this is an
        // encode of the whole archive per host event for a date nobody reads
        // until the session is gone.
        if let existing, existing.differsOnlyInClock(from: candidate),
            lastActivityAt.timeIntervalSince(existing.lastActivityAt) < Self.clockQuantum {
            return
        }
        entries[summary.key] = candidate
    }

    /// Nothing re-reads an archived row's transcript, so a rename has to land here too.
    public mutating func rename(sessionId: String, to name: String) {
        for (key, entry) in entries where entry.sessionId == sessionId {
            entries[key]?.name = name
        }
    }

    /// A session found on disk that the list has let go of, taken back so the
    /// pane can read it and typing resumes it. Dated now, or the next prune
    /// would let it go again.
    @discardableResult
    public mutating func adopt(
        sessionId: String,
        cwd: String,
        name: String?,
        model: String?,
        now: Date = Date()
    ) -> Entry {
        if let key = entries.values.first(where: {
            $0.sessionId == sessionId
        })?.key {
            entries[key]?.lastActivityAt = now
            return entries[key]!
        }
        let entry = Entry(
            key: UUID().uuidString.lowercased(),
            sessionId: sessionId,
            cwd: cwd,
            name: name,
            model: model,
            startedAt: ISO8601DateFormatter().string(from: now),
            lastActivityAt: now
        )
        entries[entry.key] = entry
        return entry
    }

    public mutating func forget(key: String) {
        entries.removeValue(forKey: key)
    }

    /// The rows for sessions the host is not running. Live ones are excluded
    /// rather than merged: the host's account of a session it holds is better
    /// than ours in every field, and two rows under one key would be one row
    /// the list draws twice.
    public func rows(
        besides live: Set<String>,
        worktree: (Entry) -> WorktreeOrigin? = { _ in nil }
    ) -> [SessionRowModel] {
        entries.values
            .filter { !live.contains($0.key) }
            .sorted { $0.lastActivityAt == $1.lastActivityAt
                ? $0.key < $1.key
                : $0.lastActivityAt < $1.lastActivityAt
            }
            .map { SessionRowModel(archived: $0, worktree: worktree($0)) }
    }

    /// What typing at a hosted pane comes to. The rule rather than the plumbing,
    /// because the difference between the two is a message posted into a socket
    /// nobody is holding: the composer clears the draft either way, so a wrong
    /// answer here is a message that was written, sent, and never anywhere.
    public enum Delivery: Equatable, Sendable {
        /// The host has it; the socket is the whole of the gesture.
        case send
        /// It doesn't, but this is what it takes to have it again.
        case resume(Entry)
        /// Neither, and nothing to be done about it — a pane older than a week,
        /// or one open on a session from before the app kept any of this.
        case gone
    }

    public func delivery(forKey key: String, live: Set<String>) -> Delivery {
        if live.contains(key) { return .send }
        guard let entry = entries[key] else { return .gone }
        return .resume(entry)
    }

    /// A folder that has gone takes its sessions with it. Worth doing rather
    /// than leaving to the resume to discover: a worktree is deleted the moment
    /// its branch lands, the SDK's account of a cwd it cannot enter blames the
    /// binary's libc rather than the folder, and the reply that says so arrives
    /// long after the one that said the resume was accepted. A row that isn't
    /// there is better than a row that swallows a message.
    ///
    /// Withheld is not missing — a folder macOS won't talk about is one you
    /// haven't granted, and the session in it is still a session.
    public mutating func prune(now: Date = Date(), probe: (any DirectoryProbe)? = nil) {
        let cutoff = now.addingTimeInterval(-Self.keepFor)
        entries = entries.filter { $0.value.lastActivityAt >= cutoff }
        if let probe {
            var known: [String: Bool] = [:]
            entries = entries.filter { entry in
                let there = known[entry.value.cwd] ?? probe.stillThere(entry.value.cwd)
                known[entry.value.cwd] = there
                return there
            }
        }
        guard entries.count > Self.capacity else { return }
        let kept = entries.values
            .sorted { $0.lastActivityAt > $1.lastActivityAt }
            .prefix(Self.capacity)
        entries = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0) })
    }
}
