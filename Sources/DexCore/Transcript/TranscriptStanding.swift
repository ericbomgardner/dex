import Foundation

/// Whose turn the end of a transcript says it is.
///
/// The list takes `working` from the CLI's record of the session, and that
/// record moves when the session posts progress rather than when it is handed
/// something: a turn that opens with a long think is written `done`, your
/// message sitting in its detail, until the first tool call lands — twenty
/// seconds on a session thinking hard, and the whole turn on one that never
/// calls a tool. The file says sooner. Your message is appended to it as it is
/// sent, so the end of the file is the first place a turn that has started can
/// be seen at all.
public enum TranscriptStanding {

    /// How much of the end of the file to read: enough for the last few records,
    /// little enough to re-read on every write. A record is as long as whatever
    /// the tool it carries returned or whatever was pasted into it, so a window
    /// filled end to end by the middle of one holds no whole record at all — and
    /// gives the same answer an empty file would, about the file most likely to
    /// have a turn owed on it. A miss widens rather than takes that answer.
    public static let windows = [256_000, 4_000_000]

    /// Whether the session owes the next word: the file ends on a message, on a
    /// tool result nobody has answered, or on a call that hasn't come back.
    ///
    /// A file that can't be read owes nothing, which leaves the row saying what
    /// the CLI's record says — the answer it gave before this was asked.
    public static func owesTurn(at url: URL, windows: [Int] = windows) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return false }

        for window in windows {
            let start = end > UInt64(window) ? end - UInt64(window) : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd()
            else { return false }

            if let owed = owesTurn(in: data, isWholeFile: start == 0) { return owed }
            if start == 0 { break }
        }
        return false
    }

    /// A window that starts mid-file starts mid-record, and half a record is not
    /// one. Nil where nothing whole was left to read, which is the caller's cue
    /// to look further back rather than to answer.
    public static func owesTurn(in data: Data, isWholeFile: Bool) -> Bool? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        return owesTurn(in: lines)
    }

    static func owesTurn(in lines: [Data]) -> Bool? {
        for line in lines.reversed() {
            guard let record = TranscriptRecord.decode(line),
                  // A subagent's turns are its own conversation, and what the CLI
                  // feeds the model of its own accord is nobody's. The call that
                  // sent the agent out is on this conversation and answers for it.
                  record.isSidechain != true,
                  record.isMeta != true,
                  let role = record.role
            else { continue }

            // Anything the session was handed is a turn it hasn't finished — bar
            // the CLI's note that a turn was stopped, which is written as a user
            // turn and is the end of one, and what a local command printed,
            // which answers the `/compact` or `/cost` before it and is the end of
            // that. An assistant turn is the end of the conversation only where
            // it left nothing running.
            guard role == .assistant else {
                return !record.isInterruption && !record.isLocalCommandOutput
            }
            return record.leftCallRunning
        }
        return nil
    }
}

extension TranscriptRecord {

    /// Whether this is the CLI saying a turn was stopped rather than anything
    /// said to the session. Nobody owes an answer to it, and reading it as a
    /// message leaves an interrupted session spinning for as long as it sits
    /// there. One text block and nothing else is the shape it is written in.
    var isInterruption: Bool {
        guard let blocks = message?.content, blocks.count == 1,
              case .text(let text) = blocks[0]
        else { return false }
        return TranscriptText.isInterruption(text)
    }

    /// Whether this turn asked for a tool. A result is a record of its own, so a
    /// call in the newest record is one nothing has come back to.
    var leftCallRunning: Bool {
        (message?.content ?? []).contains { block in
            if case .toolUse = block { return true }
            return false
        }
    }
}
