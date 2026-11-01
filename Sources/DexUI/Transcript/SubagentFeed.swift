import DexCore
import Foundation
import Observation

/// Follows one subagent's transcript, the way `TranscriptFeed` follows a
/// session's. Kept apart from it rather than folded in: a subagent has no
/// composer and no queue, and it is opened and dropped as the agent is opened
/// and closed rather than living as long as the pane does. It does have a model
/// of its own — see `SubagentIdentity` — but the row reads that off the head of
/// the same file without opening the conversation, so it does not wait on this.
///
/// Nothing starts until an agent is opened. A session that delegated twelve times
/// is twelve files nobody has read.
@MainActor
@Observable
final class SubagentFeed {

    enum Phase: Sendable, Hashable {
        /// Launched, but the agent has not opened its transcript yet.
        case starting
        case reading
        /// No transcript, and none coming — the id named one that isn't there.
        case missing
    }

    private(set) var items: [TranscriptItem] = []
    private(set) var phase: Phase = .starting

    /// Which agent is being read, and how far into its file. Kept on the feed
    /// rather than inside `run` because `run` is entered a second time for the
    /// same agent — the card follows a working agent and then reads a finished
    /// one — and starting over there would blank the turns somebody is reading.
    private var following: String?
    private var path: String?
    private var offset = 0
    private var document = TranscriptDocument(keepsSidechain: true)

    /// - Parameter follows: whether the agent is still working. A finished one is
    ///   read once and left alone; its file will not grow again.
    func run(
        agentID: String,
        in directory: String,
        follows: Bool,
        source: any TranscriptSource = LocalTranscriptSource()
    ) async {
        if following != agentID {
            following = agentID
            path = nil
            offset = 0
            document = TranscriptDocument(keepsSidechain: true)
            items = []
            phase = .starting
        }

        let wake = TranscriptWake()
        defer { wake.stop() }

        while !Task.isCancelled {
            if path == nil {
                if let found = await source.locateAgent(agentID, in: directory) {
                    path = found
                    offset = 0
                    wake.follow(source.changes(to: found))
                } else if !follows {
                    // An agent that is done and wrote nothing has nothing coming.
                    // One that is still working may not have opened its file yet,
                    // and how long that takes is its own business — so this waits
                    // rather than calling a working agent missing.
                    phase = .missing
                    return
                }
            }

            if let reading = path {
                let pass = await Self.read(reading, from: offset, through: source, into: document)
                guard !Task.isCancelled else { return }
                offset = pass.read.offset
                document = pass.document
                if let read = pass.items {
                    items = read
                    phase = .reading
                }
                if !follows {
                    if items.isEmpty { phase = .missing }
                    return
                }
            }

            await wake.wait(upTo: source.interval)
        }
    }

    private struct Pass: Sendable {
        let read: TranscriptRead
        let document: TranscriptDocument
        let items: [TranscriptItem]?
    }

    // Off the main actor: the parse and the item build take a beat on a long
    // transcript, and the pane has nothing to draw until both are done.
    nonisolated private static func read(
        _ path: String,
        from offset: Int,
        through source: any TranscriptSource,
        into document: TranscriptDocument
    ) async -> Pass {
        let read = await source.read(path, from: offset)
        var document = document
        if read.restarted { document = TranscriptDocument(keepsSidechain: true) }
        for line in read.lines { document.append(line: line) }

        let changed = read.restarted || !read.lines.isEmpty
        return Pass(
            read: read,
            document: document,
            items: changed ? TranscriptFlow.items(from: document.entries) : nil
        )
    }
}
