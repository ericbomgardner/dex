import Foundation

/// How the newest call to one MCP server went, read off the transcript. The
/// CLI's own status never moves after startup, so this is the only place a
/// server that drops mid-session shows.
public enum McpCallOutcome: Hashable, Sendable {
    case answered
    case unreachable(String, at: Date?)

    /// Only the CLI's own words for a transport failure. A tool's errors come
    /// back through the same field — "No such issue", a JSON-RPC error, a Node
    /// `ENOENT: …` thrown from a handler — and those are the server answering.
    public static func reading(_ text: String, isError: Bool, at date: Date? = nil) -> McpCallOutcome {
        guard isError else { return .answered }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return isConnectionFailure(text) ? .unreachable(text, at: date) : .answered
    }

    static func isConnectionFailure(_ text: String) -> Bool {
        if text == "Connection closed" || text.hasPrefix("Error POSTing to endpoint: ") { return true }
        if text.hasPrefix("MCP server \""),
           text.contains("\" timed out after ") || text.hasSuffix("\" session expired") { return true }
        // The CLI's fetch, not any error that opens with a code.
        guard text.range(of: #"^E[A-Z]{3,}: "#, options: .regularExpression) != nil else { return false }
        return text.contains("Unable to connect. Is the computer able to access the url?")
            || text.hasSuffix("pass `verbose: true` in the second argument to fetch()")
    }

    /// `mcp__<server>__<tool>`, the server as the CLI folds it into a tool name.
    static func server(ofTool name: String) -> String? {
        guard name.hasPrefix("mcp__") else { return nil }
        let rest = name.dropFirst(5)
        guard let split = rest.range(of: "__"), split.lowerBound > rest.startIndex else { return nil }
        return String(rest[..<split.lowerBound])
    }

    /// Newest outcome per server across `lines`, in file order. Nil where no
    /// MCP call was answered in them, so a window that saw none keeps the last.
    static func read(_ lines: [Data]) -> [String: McpCallOutcome]? {
        var servers: [String: String] = [:]
        for line in lines where line.range(of: marker) != nil {
            guard let record = TranscriptRecord.decode(line), record.role == .assistant else { continue }
            for case .toolUse(let id, let name, _) in record.message?.content ?? [] {
                if let server = server(ofTool: name) { servers[id] = server }
            }
        }
        guard !servers.isEmpty else { return nil }
        let ids = servers.keys.map { Data("\"\($0)\"".utf8) }

        var outcomes: [String: McpCallOutcome] = [:]
        for line in lines where line.range(of: resultMarker) != nil && ids.contains(where: { line.range(of: $0) != nil }) {
            // An `api-request-blob` repeats merged results unstamped, after the stamped ones.
            guard let record = TranscriptRecord.decode(line), record.role == .user else { continue }
            for case .toolResult(let id, let text, let isError) in record.message?.content ?? [] {
                if let server = servers[id] { outcomes[server] = reading(text, isError: isError, at: record.at) }
            }
        }
        return outcomes.isEmpty ? nil : outcomes
    }

    private static let marker = Data("\"mcp__".utf8)
    private static let resultMarker = Data("\"tool_result\"".utf8)
}

/// One MCP server a running session can't use, for the chip under its composer.
public struct McpTrouble: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case failed, needsAuth, unreachable
    }

    public let server: String
    public let kind: Kind
    public let detail: String?
    /// When the call that found it gone was answered; nil for a startup reading.
    public let droppedAt: Date?

    public var id: String { server }

    public init(server: String, kind: Kind, detail: String?, droppedAt: Date? = nil) {
        self.server = server
        self.kind = kind
        self.detail = detail
        self.droppedAt = droppedAt
    }

    /// The host's startup reading first, then any server whose newest call
    /// couldn't reach it. Names are compared folded, as tool names carry them.
    /// A resume reuses the transcript, so a drop from before `since` was another
    /// process's. `reconnected` holds, per server, the newest drop a reconnect
    /// mended, in the transcript's own clock so another clock's skew can't hide
    /// a later one.
    public static func of(
        servers: [HostMcpServer]?, calls: [String: McpCallOutcome], since: Date? = nil,
        reconnected: [String: Date] = [:]
    ) -> [McpTrouble] {
        let mended = Dictionary(reconnected.map { (folded($0.key), $0.value) }, uniquingKeysWith: max)
        var trouble: [McpTrouble] = (servers ?? []).compactMap { server in
            switch server.status {
            case "failed": McpTrouble(server: server.name, kind: .failed, detail: server.error)
            case "needs-auth": McpTrouble(server: server.name, kind: .needsAuth, detail: server.error)
            default: nil
            }
        }
        let named = Set(trouble.map { folded($0.server) })
        for (server, outcome) in calls.sorted(by: { $0.key < $1.key }) {
            guard case .unreachable(let error, let at) = outcome, !named.contains(server) else { continue }
            if let since, let at, at < since { continue }
            if let mend = mended[server], at.map({ $0 <= mend }) ?? true { continue }
            let name = servers?.first { folded($0.name) == server }?.name ?? server
            trouble.append(McpTrouble(server: name, kind: .unreachable, detail: error, droppedAt: at))
        }
        return trouble
    }

    static func folded(_ name: String) -> String {
        String(name.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" })
    }
}
