import Foundation

/// Where a subagent's own conversation is written, and what links it back to the
/// call that set it off.
///
/// The file sits beside the parent's rather than inside it — a session's
/// transcript is `<project>/<session-id>.jsonl`, and its agents write
/// `<project>/<session-id>/subagents/agent-<agentId>.jsonl`. Nested agents land
/// in that same flat directory rather than under their own parent, so the tree
/// is rebuilt from ids and never from paths; a depth-3 agent is one directory
/// read away, the same as a depth-1 one.
///
/// **What the link is, and where it isn't** — read off **CLI v2.1.227**, all four
/// cases measured rather than assumed:
///
///   depth 1, either kind   `toolUseResult.agentId`, structured, beside the result
///   deeper, background     the launch receipt's text, and only that: a subagent's
///                          own transcript records `toolUseResult` as null
///   deeper, foreground     nothing. The result is the agent's answer and carries
///                          no id, so its transcript is unreachable from here.
///
/// That last row is why `locate` answers nil rather than guessing. Matching a
/// call to a file by timing or by what is left over in the directory would put
/// one agent's conversation under another agent's name, which is worse than the
/// row we draw today.
public struct SubagentTranscript: Sendable {

    /// The directory a session's agents write into, given that session's own
    /// transcript. Nil for a path that isn't a transcript.
    public static func directory(besideParent parent: URL) -> URL? {
        guard parent.pathExtension == "jsonl" else { return nil }
        return parent
            .deletingPathExtension()
            .appendingPathComponent("subagents", isDirectory: true)
    }

    /// The transcript a given agent wrote, if it has written one. A background
    /// agent is named in its receipt before it opens the file, so this answers
    /// nil for the moment between launching and starting.
    public static func locate(agentID: String, in directory: URL) -> URL? {
        let file = directory.appendingPathComponent("agent-\(agentID).jsonl")
        return FileManager.default.fileExists(atPath: file.path) ? file : nil
    }

    /// How much of an agent's file to read at a time while looking for the turn
    /// that names its model.
    ///
    /// Read from the **front**, unlike every other transcript reading here,
    /// because what is wanted is the first turn rather than the newest — and
    /// reading whole files would undo the thing the pane is careful about, that
    /// a session which delegated twelve times is twelve files nobody has read.
    /// This used to be the whole read, sized off a measured worst case of 19k.
    /// Since CLI v2.1.266 the file opens with an `instructions` attachment
    /// carrying the session's CLAUDE.md and memory — as much as 190k in one sample, 42% of recent
    /// agents past 64k, worst case 221k — and that grows with the config file,
    /// so no fixed slab stays right. The read now goes chunk by chunk until the
    /// first turn. Since v2.1.300 the request records sit ahead of it as well,
    /// and the median agent's first turn is 95k in: two chunks.
    public static let identityWindow = 64 * 1_024

    /// How far in the read is allowed to go before giving up. Four times the
    /// measured worst case; a file with no assistant turn at all reads this
    /// much and no more.
    public static let identityCeiling = 1_024 * 1_024

    /// Which model and effort a given agent ran on, or nil while it has yet to
    /// take a turn. Bounded: an agent that somehow names its model past the
    /// ceiling reads as unknown, which costs a line on a row rather than a hang.
    public static func identity(agentID: String, in directory: URL) -> SubagentIdentity? {
        guard let file = locate(agentID: agentID, in: directory),
              let handle = try? FileHandle(forReadingFrom: file)
        else { return nil }
        defer { try? handle.close() }

        var scan = IdentityScan()
        while let length = scan.nextLength {
            guard let chunk = try? handle.read(upToCount: length), !chunk.isEmpty else {
                return scan.finish()
            }
            if let found = scan.feed(chunk) { return found }
        }
        let more = try? handle.read(upToCount: 1)
        return (more?.isEmpty ?? true) ? scan.finish() : nil
    }

    /// How far back from the end to look for an agent's newest turn. The same
    /// window the session digest opens with: what follows a turn is its tool
    /// results, and the CLI caps those well under this.
    public static let contextWindow = 256 * 1_024

    /// What an agent is carrying, off the newest turn in the tail of its own
    /// file — the reading the pane makes for the session, made of the agent's
    /// conversation. Nil until it has taken a turn, or where none landed in the
    /// window.
    public static func context(agentID: String, in directory: URL) -> SessionContext? {
        guard let file = locate(agentID: agentID, in: directory),
              let handle = try? FileHandle(forReadingFrom: file),
              let end = try? handle.seekToEnd()
        else { return nil }
        defer { try? handle.close() }
        let start = end > UInt64(contextWindow) ? end - UInt64(contextWindow) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else {
            return nil
        }
        return context(inTail: tail, isWholeFile: start == 0)
    }

    /// Every record in an agent's file is a sidechain one, so this keeps them
    /// where `SessionDigest` skips them as somebody else's.
    public static func context(inTail data: Data, isWholeFile: Bool) -> SessionContext? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        for line in lines.reversed() {
            guard let record = TranscriptRecord.decode(Data(line)) else { continue }
            if record.role == .assistant, let carried = record.context { return carried }
            if record.isCompactBoundary, let post = record.compactMetadata?.postTokens, post > 0 {
                return SessionContext(tokens: post, isEstimate: true)
            }
        }
        return nil
    }

    /// The front-of-file scan, one chunk at a time, apart from how a chunk is
    /// fetched: the line-carrying and the ceiling live here.
    ///
    /// Drive it with `nextLength` until it answers nil or the file ends. A file
    /// that ends — an empty read — is finished with `finish()`, which decodes
    /// an unterminated last line: a finished file's last record with no newline
    /// behind it. A file that reaches the ceiling is *not* finished unless the
    /// caller has checked that nothing follows, because what is carried there
    /// is a line the ceiling cut, and the two cases look the same from inside.
    public struct IdentityScan {
        private var carried = Data()
        public private(set) var consumed = 0

        public init() {}

        /// How much to ask for next, or nil once the ceiling is reached.
        public var nextLength: Int? {
            consumed < identityCeiling ? min(identityWindow, identityCeiling - consumed) : nil
        }

        /// Takes the next chunk and answers as soon as a complete line names a
        /// model. A partial line at the chunk's end waits for the next chunk.
        public mutating func feed(_ chunk: Data) -> SubagentIdentity? {
            let newline = UInt8(ascii: "\n")
            consumed += chunk.count
            carried.append(chunk)
            guard let lastBreak = carried.lastIndex(of: newline) else { return nil }
            let whole = Data(carried[carried.startIndex..<lastBreak])
            carried = Data(carried[carried.index(after: lastBreak)...])
            let lines: [Data] = whole
                .split(separator: newline, omittingEmptySubsequences: true)
                .map { Data($0) }
            return SubagentIdentity.read(lines: lines)
        }

        /// The file has ended: whatever is carried is its last line, complete
        /// but unterminated, and may be the first turn.
        public mutating func finish() -> SubagentIdentity? {
            defer { carried = Data() }
            return carried.isEmpty ? nil : SubagentIdentity.read(lines: [carried])
        }
    }
}
