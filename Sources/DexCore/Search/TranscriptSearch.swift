import Foundation

/// A session whose own messages, or Claude's replies, say what was searched for.
public struct TranscriptHit: Sendable, Hashable, Identifiable {
    public let sessionID: String
    public let transcript: URL
    public let cwd: String
    public var title: String?
    public var model: String?
    public let lastWrite: Date
    public let snippet: String
    /// Character offsets of the match within `snippet`.
    public let highlight: Range<Int>
    public let matches: Int

    public var id: String { sessionID }
}

/// Cmd-Shift-F across every transcript Dex ran.
/// A scan rather
/// than an index: the files are append-only logs the CLI owns, and a
/// case-folded byte scan of all of them is quicker than keeping a copy honest.
public struct TranscriptSearch: Sendable {
    public static let minimumQuery = 2
    public static let limit = 50
    static let decodedPerFile = 200

    public let configDirectory: URL
    let reopenable: @Sendable (String) -> Bool

    public init(configDirectory: URL = ConfigDirectory.resolve()) {
        self.init(configDirectory: configDirectory, reopenable: Self.isReopenable)
    }

    init(configDirectory: URL, reopenable: @escaping @Sendable (String) -> Bool) {
        self.configDirectory = configDirectory
        self.reopenable = reopenable
    }

    /// A hit is there to be continued, and a session can't resume in a folder
    /// that has gone. Probes run in the temporary directory, never anything real.
    static func isReopenable(_ cwd: String) -> Bool {
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        let folder = URL(fileURLWithPath: cwd).resolvingSymlinksInPath().path
        return !(folder + "/").hasPrefix(temporary.hasSuffix("/") ? temporary : temporary + "/")
            && FileManager.default.fileExists(atPath: folder)
    }

    var projectsDirectory: URL {
        configDirectory.appendingPathComponent("projects", isDirectory: true)
    }

    public func search(
        _ query: String,
        limit: Int = Self.limit,
        isCancelled: @Sendable () -> Bool = { false }
    ) -> [TranscriptHit] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= Self.minimumQuery else { return [] }
        let needle = Self.needle(for: query)
        let files = transcripts()

        let found = Locked<[TranscriptHit]>([])
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            guard !isCancelled() else { return }
            let file = files[index]
            guard let data = try? Data(contentsOf: file.url, options: .alwaysMapped),
                  let hit = Self.hit(
                      in: data, needle: needle, query: query,
                      transcript: file.url, lastWrite: file.lastWrite
                  )
            else { return }
            found.mutate { $0.append(hit) }
        }
        guard !isCancelled() else { return [] }

        // A session that moved folder has a file under each; the newest is the live one.
        var seen = Set<String>()
        return found.value
            .sorted { $0.lastWrite > $1.lastWrite }
            .filter { seen.insert($0.sessionID).inserted }
            .lazy.filter { reopenable($0.cwd) }
            .prefix(limit)
            .map { hit in
                var hit = hit
                let digest = SessionDigestReader.digest(at: hit.transcript)
                hit.title = digest.title
                hit.model = digest.context?.model
                return hit
            }
    }

    /// What it takes to list a session again from its transcript alone.
    public struct Facts: Sendable, Equatable {
        public let cwd: String
        public let title: String?
        public let model: String?
    }

    public func facts(sessionID: String) -> Facts? {
        guard
            let url = TranscriptLocator(configDirectory: configDirectory).locate(sessionID: sessionID),
            let handle = try? FileHandle(forReadingFrom: url),
            let head = try? handle.read(upToCount: Header.headWindow),
            let cwd = Header.read(head)?.cwd
        else { return nil }
        try? handle.close()
        let digest = SessionDigestReader.digest(at: url)
        return Facts(
            cwd: cwd,
            title: digest.title, model: digest.context?.model
        )
    }

    struct File { let url: URL; let lastWrite: Date }

    /// Top-level transcripts only: a subagent's file sits beneath its parent's
    /// folder, and its parent is the session to go back to.
    func transcripts() -> [File] {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(
            at: projectsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return folders.flatMap { folder -> [File] in
            let entries = (try? manager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )) ?? []
            return entries.compactMap { url in
                guard
                    url.pathExtension == "jsonl"
                else { return nil }
                let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return File(url: url, lastWrite: written)
            }
        }
    }

    /// The query as it appears inside a JSON string, lowercased for the fold.
    /// Node escapes quotes, backslashes and control characters, nothing else.
    /// The fold is ASCII only, so a query with other letters is narrowed to its
    /// longest ASCII run and left to the decoded check to match in full.
    static func needle(for query: String) -> [UInt8] {
        let data = (try? JSONSerialization.data(
            withJSONObject: query, options: [.fragmentsAllowed, .withoutEscapingSlashes]
        )) ?? Data(query.utf8)
        let escaped = Array(data.dropFirst().dropLast()).map(Fold.lower)
        guard escaped.contains(where: { $0 >= 0x80 }) else { return escaped }
        let longest = escaped.split(whereSeparator: { $0 >= 0x80 }).max { $0.count < $1.count }
        guard let longest, longest.count >= minimumQuery else { return escaped }
        return Array(longest)
    }

    static let toolMarkers = [#""type":"tool_use""#, #""type":"tool_result""#].map { Data($0.utf8) }
    static let textMarker = Data(#""type":"text""#.utf8)

    static func hit(
        in data: Data,
        needle: [UInt8],
        query: String,
        transcript: URL,
        lastWrite: Date
    ) -> TranscriptHit? {
        guard let head = Header.read(data), head.isDex, let cwd = head.cwd else { return nil }

        var matches = 0
        var first: (text: String, range: Range<String.Index>)?
        var decoded = 0

        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var from = 0
            while decoded < decodedPerFile, let at = Fold.find(needle, in: bytes, from: from) {
                let line = Fold.line(around: at, in: bytes)
                from = line.upperBound + 1
                let raw = Data(bytes[line])
                // The CLI writes each block as a record of its own, so a tool
                // record has nothing said in it — and in a long coding session
                // there are hundreds of them ahead of the line being looked for.
                if toolMarkers.contains(where: { raw.range(of: $0) != nil }), raw.range(of: textMarker) == nil {
                    continue
                }
                decoded += 1
                guard let record = TranscriptRecord.decode(raw),
                      let text = record.searchableText,
                      let range = text.range(of: query, options: .caseInsensitive)
                else { continue }
                matches += 1
                if first == nil { first = (text, range) }
            }
        }

        guard let first else { return nil }
        let (snippet, highlight) = Self.snippet(first.text, around: first.range)
        return TranscriptHit(
            sessionID: transcript.deletingPathExtension().lastPathComponent,
            transcript: transcript, cwd: cwd,
            lastWrite: lastWrite, snippet: snippet, highlight: highlight, matches: matches
        )
    }

    static let before = 40
    static let after = 120

    static func snippet(_ text: String, around range: Range<String.Index>) -> (String, Range<Int>) {
        let start = text.index(range.lowerBound, offsetBy: -before, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: after, limitedBy: text.endIndex) ?? text.endIndex
        let lead = start == text.startIndex ? "" : "…"
        let tail = end == text.endIndex ? "" : "…"

        func flat<S: StringProtocol>(_ part: S) -> String {
            String(part.map { $0.isNewline || $0 == "\t" ? " " : $0 })
        }
        let prefix = lead + flat(text[start..<range.lowerBound])
        let match = flat(text[range])
        let snippet = prefix + match + flat(text[range.upperBound..<end]) + tail
        let offset = prefix.count
        return (snippet, offset..<(offset + match.count))
    }

    /// Where the session ran and whether Dex ran it, off its opening records.
    /// Dex's host runs the SDK, which marks every record `sdk-ts` — `sdk-cli`
    /// under SDKs before 0.3.283; the Terminal's sessions say `cli`.
    struct Header: Decodable {
        let entrypoint: String?
        let cwd: String?

        var isDex: Bool { entrypoint?.hasPrefix("sdk") == true }

        static let headWindow = 256_000

        static func read(_ data: Data) -> Header? {
            var entrypoint: String?
            var cwd: String?
            for line in data.prefix(headWindow).split(separator: UInt8(ascii: "\n")) {
                guard let header = try? JSONDecoder().decode(Header.self, from: line) else { continue }
                entrypoint = entrypoint ?? header.entrypoint
                cwd = cwd ?? header.cwd
                if entrypoint != nil, cwd != nil { break }
            }
            guard entrypoint != nil || cwd != nil else { return nil }
            return Header(entrypoint: entrypoint, cwd: cwd)
        }
    }
}

extension TranscriptRecord {
    /// What was typed or said in the conversation itself: no tool traffic,
    /// nothing the CLI threaded in, nothing a subagent wrote.
    var searchableText: String? {
        guard role != nil, isMeta != true, isSidechain != true, isCompactSummary != true else { return nil }
        let prose = (message?.content ?? []).compactMap { block -> String? in
            if case .text(let text) = block { return text }
            if case .thinking(let text, true) = block { return text }
            return nil
        }
        guard !prose.isEmpty else { return nil }
        let cleaned = TranscriptText.cleaned(prose.joined(separator: "\n"))
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum Fold {
    static func lower(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    static func find(_ needle: [UInt8], in haystack: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard let first = needle.first, haystack.count >= needle.count else { return nil }
        let last = haystack.count - needle.count
        guard start <= last else { return nil }
        return needle.withUnsafeBufferPointer { needle in
            var index = start
            while index <= last {
                if lower(haystack[index]) == first {
                    var offset = 1
                    while offset < needle.count, lower(haystack[index + offset]) == needle[offset] { offset += 1 }
                    if offset == needle.count { return index }
                }
                index += 1
            }
            return nil
        }
    }

    static func line(around index: Int, in bytes: UnsafeBufferPointer<UInt8>) -> Range<Int> {
        let newline = UInt8(ascii: "\n")
        var start = index
        while start > 0, bytes[start - 1] != newline { start -= 1 }
        var end = index
        while end < bytes.count, bytes[end] != newline { end += 1 }
        return start..<end
    }
}

public final class Locked<Value>: @unchecked Sendable {
    private var stored: Value
    private let lock = NSLock()

    public init(_ value: Value) { stored = value }

    public var value: Value { lock.withLock { stored } }

    public func mutate(_ change: (inout Value) -> Void) {
        lock.withLock { change(&stored) }
    }
}
