# An MCP server that drops says so only in its calls (CLI v2.1.300, SDK 0.3.300)

Probe: `Sidecar/test/mcp-drop-probe.ts` — two haiku turns against a stdio server killed between them, an http server closed between them, and an http server that fails a different way per tool.

The chip under the composer names each MCP server the session can't use (`McpTrouble`, `McpTroubleChip`): failed or `needs-auth` at startup, off the host's reading ([How a session's MCP servers are doing](how-a-sessions-mcp-servers-are-doing.md)), or unreachable on the newest call to it, off the transcript (`McpCallOutcome`, `SessionDigest.mcpCalls`).

- **The status never moves after startup.** A stdio server SIGKILLed and an http server closed while the session sat idle both still read `connected` in `mcpServerStatus()`, ten seconds later and after a turn that called both. So polling it between turns finds nothing, and the host doesn't.
- **A killed stdio server is started again by the next call to it**, which is answered. Nothing records the death.
- **A dead http server shows only as that call's `tool_result`**: `is_error: true` and text, the same in the transcript as in the stream. The texts that mean the server couldn't be reached:
  - `Connection closed`, exactly — a stdio server that exited mid-call.
  - `ECONNREFUSED: Unable to connect. Is the computer able to access the url?`, `ECONNRESET: … pass \`verbose: true\` in the second argument to fetch()` — the CLI's own fetch. Only those two shapes: an `E` code alone is also what a handler's thrown `ENOENT: …` looks like.
  - `MCP server "<name>" tool "<tool>" timed out after 4s` — either transport, after `MCP_TOOL_TIMEOUT`.
  - `MCP server "<name>" session expired` — an http server answering 401 mid-session.
  - `Error POSTing to endpoint: <body>` — an http server answering 500.
- **A tool's own error comes back through the same field.** An `isError` result reads as its text (`No such issue: ABC-1`), a JSON-RPC error as its message (`internal kaboom`). Neither is the server gone, and `McpCallOutcome.isConnectionFailure` leaves both out. A text it doesn't know counts as answered: a missed drop costs less than a row lit by a tool saying no.
- **The newest call per server wins**, so the next answered call clears the chip, and so does a Reconnect from the chip, which hides the drop it was pressed on (`SessionPane.mcpReconnected`). A resume writes to the same file, so a drop stamped before the row's process started is left out. Only `assistant` calls and `user` results count: since 2.1.300 an `api-request-blob` repeats merged results with no timestamp, and read as the newest it let an old drop through ([A transcript records each request](a-transcript-records-each-request.md)). The server is the first `__` part after `mcp__`, folded the way tool names fold it (`my server` as `my_server`); the chip matches it back to the host's name where it can.
