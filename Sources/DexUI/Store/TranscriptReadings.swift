import DexCore
import Foundation

/// What each local row is read from: its transcript, kept as a digest per
/// session, re-read off the main thread, watched for writes, and looked for
/// again while a session has named a file it hasn't written yet.
@MainActor
final class TranscriptReadings {
    /// What a row's title and second line are read from — its own transcript.
    /// Re-reading it on every host event is what this avoids.
    private let digests = SessionDigestIndex()
    let transcripts: TranscriptLocator

    private var digestRefresh: Task<Void, Never>?
    private var digestRefreshQueued = false

    /// The look for a transcript that has been named but not yet written, and
    /// when the look for each session's began.
    private var transcriptWait: Task<Void, Never>?
    private var transcriptWaits: [String: Date] = [:]

    private var transcriptWatcher: TranscriptWatcher?

    /// The live sessions whose digests a refresh reads, asked as each pass starts.
    var wanted: () -> [String] = { [] }
    /// A refresh found a digest that moved; rebuild without asking for another.
    var onMoved: () -> Void = {}
    /// The quarter-second look came round; rebuild, which decides whether to look again.
    var onLook: () -> Void = {}

    init(transcripts: TranscriptLocator) {
        self.transcripts = transcripts
    }

    func latest(sessionID: String) -> SessionDigest? {
        digests.latest(sessionID: sessionID)
    }

    /// Re-reads every live session's digest off the main thread and rebuilds
    /// once if any of them moved. One pass at a time: a burst of host events
    /// asks once more when the running pass is done, not once per event.
    /// The rebuild it causes does not ask again, or a session writing steadily
    /// would keep the reader going round between events.
    func refreshDigests() {
        if digestRefresh != nil {
            digestRefreshQueued = true
            return
        }
        let wanted = wanted()
        guard !wanted.isEmpty else { return }
        let digests = self.digests
        let transcripts = self.transcripts
        let before = wanted.map { digests.latest(sessionID: $0) }

        digestRefresh = Task { [weak self] in
            let after = await Task.detached(priority: .utility) {
                wanted.map { sessionID in
                    digests.digest(
                        sessionID: sessionID,
                        locate: { transcripts.locate(sessionID: sessionID) },
                        lastWrite: { transcripts.lastWrite(at: $0) }
                    )
                }
            }.value
            guard let self else { return }
            self.digestRefresh = nil
            // Pruned here rather than on every rebuild: a rebuild draws from
            // this cache now, and one taken while the host's list was briefly
            // empty would have emptied it under every row about to come back.
            digests.retain(sessionIDs: Set(wanted))
            if zip(before, after).contains(where: { $0 != $1 }) {
                self.onMoved()
            }
            if self.digestRefreshQueued {
                self.digestRefreshQueued = false
                self.refreshDigests()
            }
        }
    }

    /// Look for a file the session has named but not yet written.
    ///
    /// A session announces its transcript before there is one — measured at
    /// 105ms between the two, against a name the CLI writes into it at 1.2s.
    /// The read above happens on the announcement and comes back empty, and
    /// nothing would look again until the host next said something, which for a
    /// session thinking its way through a first turn is the reconcile half a
    /// minute later. Neither is the row's name the only thing waiting: the
    /// watch that keeps the row current for the rest of the session is set up
    /// against the same file, and is not set up at all until it exists.
    ///
    /// Bounded by how long each look has been going rather than by the session's
    /// own age, so a file that never arrives is given up on instead of scanned
    /// for forever, and the reconcile is left to cover whatever this doesn't.
    /// The session's age would read as zero for the life of a session whose
    /// start time didn't parse — `epochMilliseconds` answers *now* rather than
    /// 1970 — and that is a look that never ends.
    func awaitTranscripts(
        _ rows: [SessionRowModel],
        given readings: [String: SessionDigest]
    ) {
        let now = Date()
        var began: [String: Date] = [:]
        var awaited = false
        for row in rows
        where row.session.sessionId != nil && (readings[row.rowID]?.isEmpty ?? true) {
            let since = transcriptWaits[row.rowID] ?? now
            began[row.rowID] = since
            if now.timeIntervalSince(since) < PollPolicy.reconcileInterval { awaited = true }
        }
        // Rebuilt rather than pruned: a session drops out of it by having a
        // transcript, and the reading it has is kept, so it cannot come back.
        transcriptWaits = began

        guard awaited else {
            transcriptWait?.cancel()
            transcriptWait = nil
            return
        }
        guard transcriptWait == nil else { return }

        transcriptWait = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard let self, !Task.isCancelled else { return }
            // Cleared before the rebuild rather than after, since the rebuild is
            // what decides whether to ask for another one.
            self.transcriptWait = nil
            self.onLook()
        }
    }

    // Watchers, which refresh ahead of the reconcile

    func startWatching(
        _ rows: [SessionRowModel],
        onWrite: @escaping (_ rowID: String, _ at: Date, _ url: URL) -> Void
    ) {
        let watcher = TranscriptWatcher(locator: transcripts, onActivity: onWrite)
        transcriptWatcher = watcher
        watcher.sync(rows: rows)
    }

    func watch(_ rows: [SessionRowModel]) {
        transcriptWatcher?.sync(rows: rows)
    }

    /// What a write says, read off the main thread: whether the session owes a
    /// turn, and (unless `sessionID` is nil) the digest the file now gives.
    func readWrite(at url: URL, live: Bool, sessionID: String?) async -> (owed: Bool, digest: SessionDigest?) {
        let digests = self.digests
        let transcripts = self.transcripts
        return await Task.detached(priority: .utility) {
            (owed: live && TranscriptStanding.owesTurn(at: url),
             // The file's own write time, which is what the merge stores
             // against its reading. This one fires on a timer behind the
             // write, so stamping the reading with *now* would agree with
             // nothing the merge ever wrote and send both callers back to
             // the file on every event.
             digest: sessionID.map {
                 digests.digest(
                     sessionID: $0,
                     locate: { url },
                     lastWrite: { transcripts.lastWrite(at: $0) }
                 )
             })
        }.value
    }

    func stop() {
        // Left running it would go on rebuilding rows four times a second, for
        // as long as the look lasts, after everything it feeds was torn down.
        transcriptWait?.cancel()
        transcriptWait = nil
        transcriptWatcher?.stop()
        transcriptWatcher = nil
    }
}
