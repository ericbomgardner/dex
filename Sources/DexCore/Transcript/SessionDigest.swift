import Foundation

/// What a row can say about a session that only its transcript knows: the title
/// the session goes by, and the last thing said in it.
///
/// Both come off the same read because they sit in the same place. A CLI session
/// is handed both by `claude agents --json` — the title as `name`, the work as a
/// job file — and a hosted one is handed neither: the host reports state, not
/// content, and writes no job file at all. So a hosted row spent its whole life
/// saying its folder name over its own path.
public struct SessionDigest: Equatable, Sendable {

    /// The user's name for the session, else the one the CLI generated. Absent until the model has been asked for one — a second or two
    /// after the first prompt, and never for a session that never got a turn.
    /// A session opened with a slash command goes by the command until then.
    public var title: String? { renamed ?? named ?? command }

    let named: String?

    /// Kept apart from `named` because the CLI goes on rewriting its own title
    /// after a rename, and a window holding only that must not undo the rename.
    let renamed: String?

    /// Kept apart from `named` so a window that misses the CLI's title can't
    /// merge the command back over it.
    let command: String?

    /// The newest thing either side said, machinery stripped and folded onto one
    /// line. Tool calls and their results are not said, so a session deep in a
    /// build still shows the last sentence it wrote rather than a diff.
    public let lastMessage: String?

    /// What the session is carrying, off the newest turn that read anything.
    /// It rides along on this read rather than earning one of its own: usage is
    /// written on every assistant turn, so it sits nearer the end of the file
    /// than the title does, and a second pass would re-read the same bytes.
    /// Measured across 172 transcripts over 500KB, the newest one was never
    /// more than 38k back, against a 256k window.
    public let context: SessionContext?


    /// How the newest call to each MCP server went, keyed by the server as tool
    /// names fold it. Nil where the window held no answered call.
    public let mcpCalls: [String: McpCallOutcome]?

    public init(
        title: String? = nil,
        renamed: String? = nil,
        command: String? = nil,
        lastMessage: String? = nil,
        context: SessionContext? = nil,
        mcpCalls: [String: McpCallOutcome]? = nil
    ) {
        self.named = title
        self.renamed = renamed
        self.command = command
        self.lastMessage = lastMessage
        self.context = context
        self.mcpCalls = mcpCalls
    }

    func opened(with command: String?) -> SessionDigest {
        SessionDigest(
            title: named, renamed: renamed, command: command,
            lastMessage: lastMessage, context: context,
            mcpCalls: mcpCalls
        )
    }

    public var isEmpty: Bool {
        guard title == nil, lastMessage == nil, context == nil else { return false }
        return true
    }

    /// A later reading only ever adds. A window that scrolled past the title
    /// still knows the last message, and answering with half of what was already
    /// on the row would blank the other half on every write.
    public func merged(over previous: SessionDigest) -> SessionDigest {
        SessionDigest(
            title: named ?? previous.named,
            renamed: renamed ?? previous.renamed,
            command: command ?? previous.command,
            lastMessage: lastMessage ?? previous.lastMessage,
            context: context ?? previous.context,
            mcpCalls: previous.mcpCalls.map { $0.merging(mcpCalls ?? [:]) { $1 } } ?? mcpCalls
        )
    }
}

public enum SessionDigestReader {

    /// The same windows `TranscriptStanding` reads, for the same reason: a record
    /// is as long as whatever was pasted into it or whatever a tool returned, so
    /// a window can land entirely inside one and hold no whole record at all.
    public static let windows = [256_000, 4_000_000]

    /// The title is rewritten as the session runs — the CLI reasserts it beside
    /// its own bookkeeping — so it is found near the end alongside the newest
    /// message. Measured, it was never more than 20k back in a
    /// 4.7MB file, which is why one window answers both halves.
    public static func digest(at url: URL, windows: [Int] = windows) -> SessionDigest {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return SessionDigest() }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd(), end > 0 else { return SessionDigest() }

        for window in windows {
            let start = end > UInt64(window) ? end - UInt64(window) : 0
            guard (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd()
            else { return SessionDigest() }

            guard let digest = digest(in: data, isWholeFile: start == 0) else {
                if start == 0 { break }
                continue
            }
            guard digest.title == nil, start > 0,
                  (try? handle.seek(toOffset: 0)) != nil,
                  let head = try? handle.read(upToCount: headWindow)
            else { return digest }
            let lines = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            return digest.opened(with: openingCommand(in: lines))
        }
        return SessionDigest()
    }

    static let headWindow = 64_000

    static let customTitleMarker = Data(#""type":"custom-title""#.utf8)

    /// The CLI generates no title for a session whose first prompt is a slash
    /// command, however many arguments it carries, and names it only once a
    /// plain prompt follows. Until then the command is the best name there is.
    static func openingCommand(in lines: [Data]) -> String? {
        for line in lines {
            guard let record = TranscriptRecord.decode(line),
                  record.type == "user", record.isMeta != true, record.isSidechain != true
            else { continue }
            return record.commandInvocation
        }
        return nil
    }

    /// A window that starts mid-file starts mid-record, and half a record is not
    /// one. Nil where nothing whole was left to read, which is the caller's cue
    /// to look further back.
    public static func digest(in data: Data, isWholeFile: Bool) -> SessionDigest? {
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        if !isWholeFile, !lines.isEmpty { lines.removeFirst() }
        return digest(in: lines, opensFile: isWholeFile)
    }

    /// Newest wins, for both halves. A missing title is not a reason to widen:
    /// a session that has not been given one yet would send every read to the far
    /// window and re-read megabytes on every write, and the index keeps the last
    /// title it saw regardless.
    static func digest(in lines: [Data], opensFile: Bool = true) -> SessionDigest? {
        var title: String?
        var renamed: String?
        var lastMessage: String?
        var context: SessionContext?
        var readAnything = false
        let mayBeRenamed = lines.contains { $0.range(of: customTitleMarker) != nil }
        var stopNote: String?
        var stoppedCalls: [String] = []

        for line in lines.reversed() {
            guard let record = TranscriptRecord.decode(line) else { continue }
            readAnything = true

            if title == nil, let written = record.aiTitle, !written.isEmpty {
                title = written
            }
            if renamed == nil, let chosen = record.customTitle, !chosen.isEmpty {
                renamed = chosen
            }

            // A subagent carries its own context, not the conversation's.
            if context == nil, record.role == .assistant, record.isSidechain != true {
                context = record.context
            }
            if context == nil, record.isCompactBoundary,
               let post = record.compactMetadata?.postTokens, post > 0 {
                context = SessionContext(tokens: post, isEstimate: true)
            }

            // Read backwards, the calls a stop cut off come after its note.
            if let note = stopNote, record.isSidechain != true, record.isMeta != true {
                let calls = record.toolNames
                if !calls.isEmpty {
                    stoppedCalls = calls + stoppedCalls
                } else if record.saidText != nil || !stoppedCalls.isEmpty {
                    lastMessage = TranscriptText.canceled(note, calls: stoppedCalls)
                    stopNote = nil
                }
            }

            if lastMessage == nil, stopNote == nil, record.isInterruption, record.isSidechain != true {
                let note = record.saidText ?? ""
                if note.contains("for tool use") {
                    stopNote = note
                } else {
                    lastMessage = TranscriptText.canceled(note, calls: [])
                }
                continue
            }

            if lastMessage == nil, stopNote == nil,
               // Only the conversation's own turns. The file gains record types
               // between releases, and one arriving with content on it would
               // otherwise be read as something the session said.
               record.role != nil,
               // A subagent's turns are its own conversation, and what the CLI
               // feeds the model of its own accord was said by nobody.
               record.isSidechain != true,
               record.isMeta != true,
               // The compaction summary is a user record typed by nobody.
               record.isCompactSummary != true,
               let said = record.saidText {
                lastMessage = said
            }

            let isNamed = renamed != nil || (title != nil && !mayBeRenamed)
            if isNamed, lastMessage != nil, context != nil { break }
        }

        if let note = stopNote {
            lastMessage = TranscriptText.canceled(note, calls: stoppedCalls)
        }
        let command = title == nil && renamed == nil && opensFile ? openingCommand(in: lines) : nil

        guard readAnything else { return nil }
        return SessionDigest(
            title: title, renamed: renamed, command: command,
            lastMessage: lastMessage, context: context,
            mcpCalls: McpCallOutcome.read(lines)
        )
    }
}

extension TranscriptRecord {

    var commandInvocation: String? {
        let raw = (message?.content ?? []).compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }
        guard raw.contains(where: { $0.contains("<command-name>") }) else { return nil }
        return saidText
    }

    var toolNames: [String] {
        (message?.content ?? []).compactMap { block in
            if case .toolUse(_, let name, _) = block { return name }
            return nil
        }
    }

    /// The prose of a turn, or nil where the turn was machinery. Tool calls and
    /// the results that answer them are records of their own, and reading either
    /// as something said would leave a row showing a diff or a stack trace where
    /// the conversation should be. A narration block counts, though: it is prose
    /// the server summarised rather than reasoning, and a turn that narrated and
    /// then asked a question has nothing else to name it by — left out, the row
    /// keeps the line from whenever the session last spoke in full.
    var saidText: String? {
        let prose = (message?.content ?? []).compactMap { block -> String? in
            if case .text(let text) = block { return text }
            if case .thinking(let text, true) = block { return text }
            return nil
        }
        guard !prose.isEmpty else { return nil }
        return SessionDigestReader.oneLine(TranscriptText.cleaned(prose.joined(separator: "\n")))
    }
}

extension SessionDigestReader {

    /// The row draws two lines of this and nothing keeps a pasted file from
    /// arriving whole, so it is folded and cut here rather than held per row.
    /// Block syntax goes with the line breaks that gave it meaning: a `##` folded
    /// into the middle of a sentence is not a heading anywhere it is shown —
    /// the row, a notification, the fleet.
    public static func oneLine(_ text: String) -> String? {
        let unblocked = text.split(whereSeparator: \.isNewline).map(strippedOfBlockSyntax)
        let folded = unblocked.joined(separator: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return folded.isEmpty ? nil : String(folded.prefix(240))
    }

    /// Leading markers only — heading hashes, blockquote brackets, list bullets,
    /// and lines that are nothing but fence or rule. Inline spans stay: the row
    /// renders those, and unrendered they still read as words.
    private static func strippedOfBlockSyntax(_ line: Substring) -> Substring {
        var line = line.drop(while: { $0 == " " || $0 == "\t" })

        // Quote brackets come off first: a fence or a rule is still one inside
        // a blockquote, and checked the other way round it prints literally.
        while line.first == ">" {
            line = line.dropFirst().drop(while: { $0 == " " })
        }

        if line.hasPrefix("```") || line.hasPrefix("~~~") { return "" }
        if line.count >= 3, let mark = line.first, "-*_".contains(mark),
           line.allSatisfy({ $0 == mark }) {
            return ""
        }

        let hashes = line.prefix(while: { $0 == "#" })
        if (1...6).contains(hashes.count), line.dropFirst(hashes.count).first == " " {
            return line.dropFirst(hashes.count + 1)
        }

        if let bullet = line.first, "-*+".contains(bullet), line.dropFirst().first == " " {
            return line.dropFirst(2)
        }

        let digits = line.prefix(while: \.isNumber)
        if !digits.isEmpty, digits.count <= 3,
           line.dropFirst(digits.count).first == ".",
           line.dropFirst(digits.count + 1).first == " " {
            return line.dropFirst(digits.count + 2)
        }

        return line
    }

    /// The folded line is a sentence the model wrote in markdown, so the inline
    /// spans render rather than showing their syntax. Links lose their attribute:
    /// a tap on the row opens the pane, and a live link would take it.
    public static func inlineMarkdown(_ text: String) -> AttributedString {
        guard var parsed = try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else { return AttributedString(text) }

        let linked = parsed.runs.compactMap { $0.link != nil ? $0.range : nil }
        for range in linked { parsed[range].link = nil }
        return parsed
    }
}

/// The last digest read for each session, kept so an unchanged transcript is
/// never read twice and so a reading that lost half its answer keeps the half it
/// had — the title is behind the window, not gone.
///
/// The file it was read from is kept too, but only for a while. Finding a
/// transcript means listing every folder under `projects` and asking each for the
/// session's file, which measured 1.5ms against 233 of them — and the list
/// rebuilds its hosted rows on every event the host sends, not only on the one
/// that changed. Holding the answer forever is the other mistake: a session that
/// changes its own directory is filed under a second folder and its first file is
/// left behind complete, so a row pinned to it would freeze at the moment of the
/// move with nothing to say it had. Amortised rather than cached: the search runs
/// again once the answer is old enough to be worth doubting.
public final class SessionDigestIndex: @unchecked Sendable {

    /// Long enough that an idle list is not searching, short enough that a
    /// transcript refiled under another folder is picked up while you watch.
    public static let relocateAfter: TimeInterval = 10

    private struct Reading {
        var digest: SessionDigest
        var writtenAt: Date?
        var url: URL
        var locatedAt: Date
    }

    private let lock = NSLock()
    private var readings: [String: Reading] = [:]

    public init() {}

    public func digest(
        sessionID: String,
        locate: () -> URL?,
        lastWrite: (URL) -> Date?,
        now: Date = Date()
    ) -> SessionDigest {
        lock.lock()
        defer { lock.unlock() }

        let existing = readings[sessionID]
        let known = existing.flatMap { reading -> URL? in
            guard now.timeIntervalSince(reading.locatedAt) < Self.relocateAfter else { return nil }
            return FileManager.default.fileExists(atPath: reading.url.path) ? reading.url : nil
        }

        guard let url = known ?? locate() else { return existing?.digest ?? SessionDigest() }
        let locatedAt = known == nil ? now : (existing?.locatedAt ?? now)

        let stamp = lastWrite(url)
        if let existing, existing.url == url, existing.writtenAt == stamp, stamp != nil {
            readings[sessionID]?.locatedAt = locatedAt
            return existing.digest
        }

        let merged = SessionDigestReader.digest(at: url)
            .merged(over: existing?.digest ?? SessionDigest())
        readings[sessionID] = Reading(
            digest: merged,
            writtenAt: stamp,
            url: url,
            locatedAt: locatedAt
        )
        return merged
    }

    /// What was last read for the session, without going to disk.
    public func latest(sessionID: String) -> SessionDigest? {
        lock.lock()
        defer { lock.unlock() }
        return readings[sessionID]?.digest
    }

    public func retain(sessionIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        readings = readings.filter { sessionIDs.contains($0.key) }
    }
}
