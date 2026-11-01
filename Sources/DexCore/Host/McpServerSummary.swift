import Foundation

/// One MCP server across every running session that names it. Sessions can
/// disagree — one started before a server was fixed, one in a project with its
/// own `.mcp.json` — so the worst status is shown, with how many say it.
public struct McpServerSummary: Hashable, Sendable, Identifiable {
    public let name: String
    public let status: String
    public let error: String?
    /// Sessions that name the server, and how many of them report `status`.
    public let reporting: Int
    public let agreeing: Int

    public var id: String { name }

    public var isHealthy: Bool { status == "connected" || status == "disabled" }

    public static func of(_ sessions: [HostSessionSummary]) -> [McpServerSummary] {
        let readings = sessions.flatMap { $0.mcpServers ?? [] }
        return Dictionary(grouping: readings, by: \.name)
            .map { name, readings in
                let worst = readings.min { rank($0.status) < rank($1.status) }!
                let error = readings.first { $0.status == worst.status && $0.error != nil }?.error
                return McpServerSummary(
                    name: name, status: worst.status, error: error,
                    reporting: readings.count,
                    agreeing: readings.filter { $0.status == worst.status }.count)
            }
            .sorted { ($0.isHealthy ? 1 : 0, $0.name) < ($1.isHealthy ? 1 : 0, $1.name) }
    }

    /// Lowest is worst. A status this build hasn't heard of sits with `pending`:
    /// neither a failure nor a working server as far as anything here knows.
    private static func rank(_ status: String) -> Int {
        switch status {
        case "failed": 0
        case "needs-auth": 1
        case "connected": 4
        case "disabled": 3
        default: 2
        }
    }
}
