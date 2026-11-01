# How a session's MCP servers are doing (CLI v2.1.283, SDK 0.3.283)

Probe: `Sidecar/test/mcp-status-probe.ts` — one short haiku turn, against a stdio server it writes and an http server on a dead port.

Settings → MCP servers shows each server as the running sessions report it (`McpServerSummary.of`, `SessionStore.mcpServers`). The chip under a session's composer names its own `failed` and `needs-auth` servers ([Reconnecting and logging in to an MCP server](reconnecting-and-logging-in-to-an-mcp-server.md)); a server that drops later never changes status ([An MCP server that drops says so only in its calls](an-mcp-server-that-drops-says-so-only-in-its-calls.md)).

- **The `system`/`init` frame carries `mcp_servers`: `name`, `status`, `source`, and no error.** A failed server reads `failed` there with nothing to say why.
- **`mcpServerStatus()` has the `error`** (e.g. `ECONNREFUSED: Unable to connect…`), plus `config`, which is dropped because it can hold tokens. The host calls it after every `init` and after every result (`#reportMcp`), then every 5s for up to a minute while any server reads `pending`, and posts `session.mcp` only when the readings changed. It is posted, not emitted: a server connecting is not the session doing anything, and must not keep it from the reaper.
- **Only on a streamed query.** With a string prompt the query closes at the result, and `mcpServerStatus()` asked after that throws `Query closed before response received`. The host always streams, so it works there.
- Statuses seen: `connected`, `failed`. The SDK's type also lists `needs-auth`, `pending`, `disabled`. Both a local stdio server and a failed http one had already settled by `init` in this probe, but the host asks again anyway in case a slower one is still `pending`. `HostMcpServer.status` is kept as a string so a new status still shows.
- **A stdio server is started from the session's own environment, by whatever name its config gives.** `npx` or `uvx` alone fails with `Executable not found in $PATH` unless the host has the login PATH; an app opened from Finder only has launchd's, so `HostClient.hostEnvironment` hands the host `LoginShell.path()`.
- `mcpServers` on `session.init` and the summary is **nil from a host that predates it**, and that means "hasn't said", not "has no servers".

